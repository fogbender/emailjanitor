defmodule EmailJanitor.RecoveryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Executor,
    Inbox,
    Owner,
    Reviewer,
    Store,
    TestClassifier,
    TestGmail,
    TestRepo
  }

  alias EmailJanitor.Store.{Action, Scope}

  defp database(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  setup do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    {:ok, box} = Inbox.new("recovery-" <> suffix, "owner-" <> suffix <> "@acme.com")
    {:ok, scope} = Scope.new(TestRepo, "ej_recovery")
    database(fn -> {:ok, _} = Store.add_inbox(scope, box) end)
    {:ok, proposal} = Reviewer.review([message()], box, MapSet.new(), {TestClassifier, []}, "", 1)
    %{scope: scope, box: box, proposal: proposal}
  end

  defp owner(ctx, fun) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        database(fn ->
          {:ok, {:created, action}} = Store.intent(ctx.scope, ctx.box.id, ctx.proposal, "100")
          send(parent, {:prepared, self(), action})
          fun.(action, parent)
        end)
      end)

    assert_receive {:prepared, ^pid, action}, 5_000
    {pid, monitor, action}
  end

  defp expire(ctx, id) do
    database(fn ->
      TestRepo.update_all(
        from(a in Action, where: a.id == ^id),
        [
          set: [
            lease_expires_at: DateTime.add(DateTime.utc_now(), -1)
          ]
        ],
        prefix: ctx.scope.prefix
      )
    end)
  end

  defp beam_owner(ctx, dispatch?) do
    payload =
      {ctx.scope.prefix, ctx.box.id, ctx.proposal, dispatch?}
      |> :erlang.term_to_binary()
      |> Base.encode64()

    script = """
    {:ok, _} = Application.ensure_all_started(:email_janitor)
    {:ok, _} = EmailJanitor.TestRepo.start_link(
      socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"), database: "emailjanitor_test",
      username: System.fetch_env!("USER"), port: 5432, log: false)
    [encoded] = System.argv()
    {prefix, inbox, proposal, dispatch?} = encoded |> Base.decode64!() |> :erlang.binary_to_term()
    {:ok, scope} = EmailJanitor.Store.Scope.new(EmailJanitor.TestRepo, prefix)
    {:ok, {:created, action}} = EmailJanitor.Store.intent(scope, inbox, proposal, "100")
    if dispatch?, do: :ok = EmailJanitor.Store.begin_dispatch(scope, inbox, action.id, action.owner_token)
    IO.puts("READY:" <> action.id)
    Process.sleep(:infinity)
    """

    paths = Path.wildcard("_build/test/lib/*/ebin") |> Enum.flat_map(&["-pa", &1])
    args = ["--erl", "+S 2:2"] ++ paths ++ ["-e", script, "--", payload]

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port),
        do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    action_id = beam_ready(port, "")
    action = database(fn -> Store.get(ctx.scope, ctx.box.id, action_id) end)
    assert action.owner_os_pid == Integer.to_string(os_pid)
    {port, os_pid, action}
  end

  defp beam_ready(port, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        case Regex.run(~r/READY:([a-f0-9-]{36})/, output) do
          [_, id] -> id
          _ -> beam_ready(port, output)
        end
    after
      10_000 -> flunk("isolated BEAM did not commit its intent")
    end
  end

  test "a process crash after committed preparation survives a new database connection", ctx do
    {pid, monitor, action} = owner(ctx, fn _, _ -> Process.exit(self(), :kill) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

    assert %Action{state: :intent} =
             database(fn -> Store.get(ctx.scope, ctx.box.id, action.id) end)

    assert {:ok, {:cancelled, _}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    assert %Action{state: :cancelled, applied_message_ids: []} =
             database(fn -> Store.get(ctx.scope, ctx.box.id, action.id) end)
  end

  test "an in-flight live owner cannot be cancelled even with complete empty history", ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        :ok = Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)
        send(parent, {:dispatching, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:dispatching, ^pid}

    assert {:error, :owner_not_proven_dead} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    assert {:error, :state_changed} =
             database(fn ->
               Store.reconcile(ctx.scope, ctx.box.id, action.id, %{complete?: true, events: []})
             end)

    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  test "an expired suspended owner is terminated before recovery and cannot resume dispatch",
       ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        receive do
          :dispatch ->
            result = Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)
            send(parent, {:resumed, result})
        end
      end)

    :erlang.suspend_process(pid)
    expire(ctx, action.id)

    assert {:ok, {:cancelled, _}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    send(pid, :dispatch)
    refute Process.alive?(pid)
    refute_received {:resumed, _}
  end

  test "an expired owner cannot pass the last dispatch fence without a recovery process", ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        receive do
          :dispatch ->
            send(
              parent,
              {:fenced,
               Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)}
            )
        end
      end)

    expire(ctx, action.id)
    send(pid, :dispatch)
    assert_receive {:fenced, {:error, :ownership_lost}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  test "a dispatch waiting behind a locked recovery decision observes the committed cancellation",
       ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        receive do
          :dispatch ->
            send(
              parent,
              {:fenced,
               Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)}
            )
        end
      end)

    parent = self()

    {locker, lock_monitor} =
      spawn_monitor(fn ->
        database(fn ->
          TestRepo.transaction(fn ->
            TestRepo.one!(from(a in Action, where: a.id == ^action.id, lock: "FOR UPDATE"),
              prefix: ctx.scope.prefix
            )

            send(parent, :row_locked)

            receive do
              :cancel ->
                TestRepo.update_all(
                  from(a in Action, where: a.id == ^action.id),
                  [set: [state: :cancelled]],
                  prefix: ctx.scope.prefix
                )
            end
          end)
        end)
      end)

    assert_receive :row_locked, 5_000
    send(pid, :dispatch)
    assert wait_for_dispatch_lock(ctx)
    send(locker, :cancel)
    assert_receive {:DOWN, ^lock_monitor, :process, ^locker, :normal}, 5_000
    assert_receive {:fenced, {:error, :ownership_lost}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000

    assert %Action{state: :cancelled, dispatch_started_at: nil} =
             database(fn -> Store.get(ctx.scope, ctx.box.id, action.id) end)
  end

  defp wait_for_dispatch_lock(ctx, tries \\ 100)
  defp wait_for_dispatch_lock(_, 0), do: false

  defp wait_for_dispatch_lock(ctx, tries) do
    %{rows: [[waiting]]} =
      database(fn ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE $1)",
          ["%" <> ctx.scope.prefix <> "%FOR UPDATE%"],
          log: false
        )
      end)

    if waiting do
      true
    else
      Process.sleep(10)
      wait_for_dispatch_lock(ctx, tries - 1)
    end
  end

  test "recover itself waits for a real dispatch fence row lock", ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        receive do
          :dispatch ->
            :ok = Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)
            send(parent, {:dispatched, self()})
            Process.exit(self(), :kill)
        end
      end)

    handler = {__MODULE__, Ecto.UUID.generate()}
    prefix = TestRepo.config()[:telemetry_prefix] || [:email_janitor, :test_repo]

    :ok =
      :telemetry.attach(handler, prefix ++ [:query], &__MODULE__.pause_fence_read/4, %{
        pid: pid,
        parent: self()
      })

    on_exit(fn ->
      :telemetry.detach(handler)
      Process.exit(pid, :kill)
    end)

    send(pid, :dispatch)
    assert_receive {:fence_row_held, ^pid}, 5_000

    parent = self()

    {recovery, recovery_monitor} =
      spawn_monitor(fn ->
        result = database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)
        send(parent, {:recovery_result, result})
      end)

    on_exit(fn -> Process.exit(recovery, :kill) end)
    assert wait_for_dispatch_lock(ctx)
    refute_received {:recovery_result, _}
    send(pid, :release_fence)
    assert_receive {:dispatched, ^pid}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    assert_receive {:recovery_result, result}, 5_000
    assert_receive {:DOWN, ^recovery_monitor, :process, ^recovery, :normal}, 5_000

    result =
      if result == {:error, :owner_not_proven_dead},
        do: database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end),
        else: result

    assert {:ok, {:unresolved, %Action{dispatch_started_at: %DateTime{}}}} = result
  end

  def pause_fence_read(_, _, metadata, context) do
    if self() == context.pid and String.contains?(metadata.query, "FOR UPDATE") and
         String.contains?(metadata.query, "actions") do
      send(context.parent, {:fence_row_held, self()})

      receive do
        :release_fence -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  test "application and restoration after an executor crash settle without another Gmail mutation",
       ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        :ok = Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)
        send(parent, {:sent_before_crash, self()})
        Process.exit(self(), :kill)
      end)

    assert_receive {:sent_before_crash, ^pid}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

    assert {:ok, {:unresolved, recovered}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    assert {:error, :fresh_history_required} =
             database(fn ->
               Store.reconcile(ctx.scope, ctx.box.id, action.id, %{complete?: true, events: []})
             end)

    history = %{
      complete?: true,
      started_at: DateTime.add(recovered.recovered_at, 1, :microsecond),
      events: [
        %{history_id: "101", message_id: "message-1", event: :inbox_removed},
        %{history_id: "102", message_id: "message-1", event: :inbox_added}
      ]
    }

    assert {:ok, {:restored, _}} =
             database(fn -> Store.reconcile(ctx.scope, ctx.box.id, action.id, history) end)

    assert MapSet.new(["message-1"]) ==
             database(fn -> Store.restored_ids(ctx.scope, ctx.box.id) end)

    changed = message(labels: ["INBOX", "IMPORTANT"])

    {:ok, fresh} =
      Reviewer.review(
        [changed],
        ctx.box,
        MapSet.new(),
        {TestClassifier, []},
        "New preferences.",
        2
      )

    database(fn ->
      TestRepo.update_all(
        from(m in EmailJanitor.Store.Mailbox, where: m.id == ^ctx.box.id),
        [set: [instruction_version: 2]],
        prefix: ctx.scope.prefix
      )

      assert {:ok, {:existing, %Action{state: :restored}}} =
               Store.intent(ctx.scope, ctx.box.id, fresh, "200")
    end)
  end

  test "death before dispatch proves non-application and permits a fresh checked attempt", ctx do
    {pid, monitor, action} =
      owner(ctx, fn _, _ -> Process.exit(self(), :kill) end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

    assert {:ok, {:cancelled, _}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    state =
      start_supervised!({Agent, fn -> %{messages: [message()], contacted: [], calls: []} end})

    assert {:done, next_id} =
             database(fn ->
               Executor.execute(ctx.scope, ctx.box, ctx.proposal, {TestGmail, [state: state]})
             end)

    refute next_id == action.id
    assert [["message-1"]] == Agent.get(state, & &1.calls)
  end

  test "different-host ownership remains unknown even when expired", ctx do
    database(fn ->
      {:ok, {:created, action}} = Store.intent(ctx.scope, ctx.box.id, ctx.proposal, "100")

      TestRepo.update_all(
        from(a in Action, where: a.id == ^action.id),
        [
          set: [
            owner_runtime: "remote-runtime",
            owner_host: "remote-host",
            lease_expires_at: DateTime.add(DateTime.utc_now(), -1)
          ]
        ],
        prefix: ctx.scope.prefix
      )

      assert {:error, :owner_not_proven_dead} = Store.recover(ctx.scope, ctx.box.id, action.id)
    end)
  end

  test "fresh empty history cannot release a sent orphan while Gmail might apply it later", ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, _ ->
        :ok = Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)
        Process.exit(self(), :kill)
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

    assert {:ok, {:unresolved, recovered}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    history = %{complete?: true, started_at: DateTime.utc_now(), events: []}

    assert {:error, :dispatch_outcome_unknown} =
             database(fn -> Store.reconcile(ctx.scope, ctx.box.id, action.id, history) end)

    state =
      start_supervised!({Agent, fn -> %{messages: [message()], contacted: [], calls: []} end})

    assert {:existing, id, :unresolved} =
             database(fn ->
               Executor.execute(ctx.scope, ctx.box, ctx.proposal, {TestGmail, [state: state]})
             end)

    assert id == action.id
    assert [] == Agent.get(state, & &1.calls)

    late_history = %{
      history
      | started_at: DateTime.add(recovered.recovered_at, 1, :microsecond),
        events: [%{history_id: "101", message_id: "message-1", event: :inbox_removed}]
    }

    assert {:ok, {:done, _}} =
             database(fn -> Store.reconcile(ctx.scope, ctx.box.id, action.id, late_history) end)
  end

  test "an expired suspended dispatched owner is killed and remains ambiguous", ctx do
    {pid, monitor, action} =
      owner(ctx, fn action, parent ->
        :ok = Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)
        send(parent, {:fence_passed, self()})

        receive do
          :resume -> send(parent, :unsafe_send)
        end
      end)

    assert_receive {:fence_passed, ^pid}
    :erlang.suspend_process(pid)
    expire(ctx, action.id)

    assert {:ok, {:unresolved, _}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    send(pid, :resume)
    refute_received :unsafe_send
  end

  test "Linux process identity permits restart recovery only after the old OS process dies",
       ctx do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    [_, rest] =
      Regex.run(~r/\A\d+ \(.*\) (.*)\z/s, File.read!("/proc/#{os_pid}/stat") |> String.trim())

    start = Enum.at(String.split(rest), 19)

    action =
      database(fn ->
        {:ok, {:created, action}} = Store.intent(ctx.scope, ctx.box.id, ctx.proposal, "100")

        TestRepo.update_all(
          from(a in Action, where: a.id == ^action.id),
          [
            set: [
              owner_runtime: "previous-runtime",
              owner_os_pid: Integer.to_string(os_pid),
              owner_os_start: start
            ]
          ],
          prefix: ctx.scope.prefix
        )

        Store.get(ctx.scope, ctx.box.id, action.id)
      end)

    assert Owner.proof(action) == :unknown

    assert {:error, :owner_not_proven_dead} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, _}}, 5_000
    assert Owner.proof(action) == :dead

    assert {:ok, {:cancelled, _}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)
  end

  test "bounded dispatch terminates a hung owner rather than leaving a live sender forever" do
    {pid, monitor} =
      spawn_monitor(fn -> Owner.bounded(fn -> Process.sleep(:infinity) end, 20) end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
  end

  for dispatch? <- [false, true] do
    test "separate BEAM SIGKILL recovers a committed #{if dispatch?, do: "dispatched", else: "prepared"} action",
         ctx do
      {port, os_pid, action} = beam_owner(ctx, unquote(dispatch?))
      assert Owner.proof(action) == :unknown
      {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
      assert_receive {^port, {:exit_status, _}}, 5_000
      assert Owner.proof(action) == :dead

      expected = if unquote(dispatch?), do: :unresolved, else: :cancelled

      assert {:ok, {^expected, _}} =
               database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)
    end
  end

  test "a failed dedicated owner cannot strand or kill its reusable caller", ctx do
    caller = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :executor_unavailable} =
                 Owner.run(fn ->
                   database(fn ->
                     {:ok, {:created, action}} =
                       Store.intent(ctx.scope, ctx.box.id, ctx.proposal, "100")

                     send(caller, {:isolated, self(), action})
                     raise "PRIVATE_EMAIL_SENTINEL"
                   end)
                 end)
      end)

    refute log =~ "PRIVATE_EMAIL_SENTINEL"
    assert_receive {:isolated, owner, action}
    refute owner == caller
    assert Process.alive?(caller)
    assert Owner.proof(action) == :dead

    assert {:ok, {:cancelled, _}} =
             database(fn -> Store.recover(ctx.scope, ctx.box.id, action.id) end)

    assert Process.alive?(caller)
  end

  test "Linux proof treats changed boots as dead but missing identity as unknown" do
    action = struct(Action, Owner.capture())
    old = %{action | owner_runtime: "old-runtime", owner_boot: "old-boot"}
    assert Owner.proof(old) == :dead
    assert Owner.proof(%{old | owner_host: nil}) == :unknown
    assert Owner.proof(%{old | owner_os_start: nil}) == :unknown
    assert Owner.proof(%{old | owner_boot: nil}) == :unknown

    assert Owner.proof(%{old | owner_boot: action.owner_boot, owner_os_pid: "invalid"}) ==
             :unknown
  end

  test "an unsupported current host cannot claim another runtime is dead" do
    key = {Owner, :runtime}
    action = struct(Action, Owner.capture())
    runtime = :persistent_term.get(key)

    try do
      :persistent_term.put(key, %{runtime | owner_host: nil, owner_boot: nil})
      assert Owner.proof(%{action | owner_runtime: "previous-runtime"}) == :unknown
    after
      :persistent_term.put(key, runtime)
    end
  end

  test "concurrent captures agree on one runtime identity" do
    runtimes =
      1..24
      |> Task.async_stream(fn _ -> Owner.capture().owner_runtime end)
      |> Enum.map(fn {:ok, id} -> id end)

    assert length(Enum.uniq(runtimes)) == 1
  end
end
