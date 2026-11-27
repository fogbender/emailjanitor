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

  test "concurrent captures agree on one runtime identity" do
    runtimes =
      1..24
      |> Task.async_stream(fn _ -> Owner.capture().owner_runtime end)
      |> Enum.map(fn {:ok, id} -> id end)

    assert length(Enum.uniq(runtimes)) == 1
  end
end
