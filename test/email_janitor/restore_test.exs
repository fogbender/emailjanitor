defmodule EmailJanitor.RestoreTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, Executor, Fixtures, Restore, Store}
  alias EmailJanitor.Restore.{Effect, Protection}
  alias EmailJanitor.Store.Scope
  alias __MODULE__.Repo

  setup_all do
    start_supervised!(
      {Repo,
       socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
       database: "emailjanitor_test",
       username: System.fetch_env!("USER"),
       port: 5432,
       pool_size: 10,
       log: false}
    )

    :ok
  end

  setup do
    prefix = "ej_restore_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, scope} = Scope.new(Repo, prefix)
    :ok = Restore.install(scope)
    box = Fixtures.inbox()
    {:ok, _} = Store.add_inbox(scope, box)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             messages: [Fixtures.message(), Fixtures.message(id: "message-2")],
             contacted: [],
             calls: [],
             restores: [],
             mode: :ok
           }
         end}
      )

    gmail = {EmailJanitor.TestGmail, [state: state]}

    assert {:ok, proposal} =
             Executor.review(
               scope,
               box,
               "thread-1",
               gmail,
               {EmailJanitor.TestClassifier, []},
               "Synthetic instructions",
               1
             )

    assert {:done, action_id} = Executor.execute(scope, box, proposal, gmail)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, ~s|DROP SCHEMA "#{prefix}" CASCADE|, [], log: false)
    end)

    %{
      scope: scope,
      box: box,
      state: state,
      action_id: action_id,
      effect_id: Ecto.UUID.generate(),
      gmail: {__MODULE__.Gmail, [state: state]}
    }
  end

  defp restore(ctx, options \\ []),
    do:
      Restore.apply(
        ctx.scope,
        ctx.box,
        ctx.effect_id,
        ctx.action_id,
        ["message-1"],
        ctx.gmail,
        [expected_instruction_version: 1] ++ options
      )

  defp effects(ctx), do: Repo.all(Effect, prefix: ctx.scope.prefix)
  defp read(ctx), do: Agent.get(ctx.state, & &1)

  test "exact restoration protects IDs durably before wire and preserves sibling labels", ctx do
    owner = self()

    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         before_wire: fn ->
           assert Store.restored_ids(ctx.scope, ctx.box.id) == MapSet.new(["message-1"])
           assert [%Effect{state: :intent, dispatch_started_at: %DateTime{}}] = effects(ctx)
           send(owner, :protection_before_wire)
         end
       ]}

    assert :ok = Restore.install(ctx.scope)
    assert {:done, id} = restore(%{ctx | gmail: gmail})
    assert id == ctx.effect_id
    assert_received :protection_before_wire
    assert read(ctx).restores == [["message-1"]]
    [first, second] = read(ctx).messages
    assert Enum.sort(first.labels) == ["IMPORTANT", "INBOX", "UNREAD"]
    assert second.labels == ["UNREAD", "IMPORTANT"]
    assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).state == :done
    assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).restored_message_ids == []

    assert Repo.all(Protection, prefix: ctx.scope.prefix) |> Enum.map(& &1.message_id) == [
             "message-1"
           ]

    assert {:existing, :done, ^id} = restore(ctx)
    assert read(ctx).restores == [["message-1"]]
  end

  test "unconfirmed, duplicate, wrong-thread IDs and changed UUID bindings never mutate", ctx do
    assert {:error, :invalid_restore_selection} =
             Restore.apply(
               ctx.scope,
               ctx.box,
               ctx.effect_id,
               ctx.action_id,
               ["message-1", "message-1"],
               ctx.gmail
             )

    assert {:error, :unconfirmed_suppression} =
             Restore.apply(
               ctx.scope,
               ctx.box,
               ctx.effect_id,
               ctx.action_id,
               ["not-janitor-applied"],
               ctx.gmail
             )

    assert effects(ctx) == [] and read(ctx).restores == []
    assert {:done, _} = restore(ctx)

    assert {:error, :effect_conflict} =
             Restore.apply(
               ctx.scope,
               ctx.box,
               ctx.effect_id,
               ctx.action_id,
               ["message-2"],
               ctx.gmail
             )

    assert read(ctx).restores == [["message-1"]]
  end

  test "wrong scoped account and disconnected authorization fail closed", ctx do
    wrong = %{ctx.box | address: "another@acme.com"}

    assert {:error, :wrong_inbox} =
             Restore.apply(
               ctx.scope,
               wrong,
               ctx.effect_id,
               ctx.action_id,
               ["message-1"],
               ctx.gmail
             )

    assert {:error, :connection_changed} =
             restore(ctx, authorize: fn -> {:error, :disconnected} end)

    assert effects(ctx) == [] and read(ctx).restores == []
  end

  test "host binding and mailbox version are checked after preparation and at final fence", ctx do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if value < 3, do: :ok, else: {:error, :disconnected}
    end

    assert {:error, :connection_changed} = restore(ctx, authorize: authorize)
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert read(ctx).restores == []
    assert MapSet.member?(Store.restored_ids(ctx.scope, ctx.box.id), "message-1")
    assert {:existing, :cancelled, _} = restore(ctx)

    new = %{
      ctx
      | effect_id: Ecto.UUID.generate(),
        gmail:
          {__MODULE__.Gmail,
           [
             state: ctx.state,
             on_prepare: fn ->
               Repo.update_all(EmailJanitor.Store.Mailbox, [inc: [instruction_version: 1]],
                 prefix: ctx.scope.prefix
               )
             end
           ]}
    }

    assert {:error, :instructions_changed} = restore(new)
    assert length(effects(ctx)) == 1
    assert read(ctx).restores == []
  end

  test "ambiguous provider failures and process death never auto-resend and retain protections",
       ctx do
    Agent.update(ctx.state, &%{&1 | mode: :timeout})
    assert {:unresolved, id} = restore(ctx)
    assert id == ctx.effect_id
    assert {:existing, :unresolved, ^id} = restore(ctx)
    assert read(ctx).restores == [["message-1"]]
    assert {:error, :restore_pending} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
    assert MapSet.member?(Store.restored_ids(ctx.scope, ctx.box.id), "message-1")

    second = %{
      ctx
      | effect_id: Ecto.UUID.generate(),
        gmail:
          {__MODULE__.Gmail,
           [state: ctx.state, before_wire: fn -> Process.exit(self(), :kill) end]}
    }

    assert {:unresolved, dead_id} =
             Restore.apply(
               second.scope,
               second.box,
               second.effect_id,
               second.action_id,
               ["message-2"],
               second.gmail
             )

    assert {:existing, :unresolved, ^dead_id} =
             Restore.apply(
               second.scope,
               second.box,
               second.effect_id,
               second.action_id,
               ["message-2"],
               second.gmail
             )

    assert Enum.sort(MapSet.to_list(Store.restored_ids(ctx.scope, ctx.box.id))) == [
             "message-1",
             "message-2"
           ]
  end

  test "concurrent same-UUID and overlapping new-UUID attempts cannot issue a second wire request",
       ctx do
    owner = self()

    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         before_wire: fn ->
           send(owner, {:dispatch_waiting, self()})

           receive do
             :continue -> :ok
           after
             2_000 -> flunk("wire task not released")
           end
         end
       ]}

    task = Task.async(fn -> restore(%{ctx | gmail: gmail}) end)
    assert_receive {:dispatch_waiting, worker}, 2_000
    assert {:existing, :unresolved, _} = restore(ctx)
    assert {:error, :restore_pending} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
    send(worker, :continue)
    assert {:done, _} = Task.await(task)
    assert read(ctx).restores == [["message-1"]]
  end

  test "a dead no-wire owner cancels and allows only a fresh explicit effect UUID", ctx do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :dead_guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if value == 3, do: Process.exit(self(), :kill), else: :ok
    end

    assert {:error, :executor_unavailable} = restore(ctx, authorize: authorize)
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert {:existing, :cancelled, _} = restore(ctx)
    assert {:done, _} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
    assert read(ctx).restores == [["message-1"]]
  end

  test "expired budgets stop both before intent and after reservation without any mutation",
       ctx do
    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         on_prepare: fn ->
           Process.put(
             {EmailJanitor.Owner, :execution_deadline},
             System.monotonic_time(:millisecond)
           )
         end
       ]}

    assert {:error, :dispatch_window_exhausted} = restore(%{ctx | gmail: gmail})
    assert effects(ctx) == []
    counter = start_supervised!({Agent, fn -> 0 end}, id: :budget_guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if value == 3,
        do:
          Process.put(
            {EmailJanitor.Owner, :execution_deadline},
            System.monotonic_time(:millisecond)
          )

      :ok
    end

    assert {:error, :dispatch_window_exhausted} = restore(ctx, authorize: authorize)
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert read(ctx).restores == []
  end

  test "source action must belong to the exact scoped inbox and protections reach normal review",
       ctx do
    other = %{Fixtures.inbox("other@acme.com") | id: "inbox-2"}
    assert {:ok, _} = Store.add_inbox(ctx.scope, other)

    assert {:error, :unconfirmed_suppression} =
             Restore.apply(
               ctx.scope,
               other,
               ctx.effect_id,
               ctx.action_id,
               ["message-1"],
               ctx.gmail
             )

    assert {:done, _} = restore(ctx)

    assert {:keep, :manually_restored} =
             Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               {EmailJanitor.TestGmail, [state: ctx.state]},
               {EmailJanitor.TestClassifier, [notify: self()]},
               "Synthetic instructions",
               1
             )

    refute_received {:classified, _, _}
  end

  test "a real disconnect queued behind reservation defeats the final restore fence", ctx do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end}, id: :disconnect_guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if value == 2 do
        caller = self()

        {:ok, _} =
          Task.start(fn ->
            Repo.transaction(fn ->
              %{rows: [[backend]]} =
                Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [], log: false)

              send(caller, {:disconnect_backend, backend})

              Ecto.Adapters.SQL.query!(
                Repo,
                ~s|SELECT id FROM "#{ctx.scope.prefix}".inboxes WHERE id = $1 FOR UPDATE|,
                [ctx.box.id],
                log: false
              )

              Repo.update_all(EmailJanitor.Store.Mailbox, [inc: [instruction_version: 1]],
                prefix: ctx.scope.prefix,
                log: false
              )
            end)

            send(owner, :disconnected)
          end)

        receive do
          {:disconnect_backend, backend} -> await_blocked(backend, 200)
        after
          2_000 -> flunk("disconnect did not start")
        end
      end

      :ok
    end

    assert {:error, :instructions_changed} = restore(ctx, authorize: authorize)
    assert_receive :disconnected, 2_000
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert read(ctx).restores == []
    assert MapSet.member?(Store.restored_ids(ctx.scope, ctx.box.id), "message-1")
  end

  defp await_blocked(_, 0), do: flunk("disconnect did not queue behind mailbox reservation")

  defp await_blocked(backend, attempts) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT cardinality(pg_blocking_pids($1))", [backend],
        log: false
      )

    if count > 0,
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_blocked(backend, attempts - 1)
        )
  end

  test "errors and ordinary inspection expose no transient contents or raw provider failures",
       ctx do
    import ExUnit.CaptureLog

    gmail =
      {__MODULE__.Gmail, [state: ctx.state, on_prepare: fn -> raise "PRIVATE_SECRET_BODY" end]}

    logs =
      capture_log(fn -> assert {:error, :gmail_unavailable} = restore(%{ctx | gmail: gmail}) end)

    refute logs =~ "PRIVATE_SECRET_BODY"
    assert effects(ctx) == []
    assert {:done, _} = restore(ctx)
    refute inspect(effects(ctx)) =~ "owner_beam_pid"
    assert Enum.all?(read(ctx).messages, &match?(%Content{}, &1.body))
  end
end

defmodule EmailJanitor.RestoreTest.Repo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.RestoreTest.Gmail do
  def prepare_add_inbox(_, ids, opts) do
    if callback = opts[:on_prepare], do: callback.()

    {:ok,
     fn ->
       if callback = opts[:before_wire], do: callback.()

       Agent.get_and_update(opts[:state], fn state ->
         messages =
           Enum.map(state.messages, fn message ->
             if message.id in ids,
               do: %{message | labels: Enum.uniq(["INBOX" | message.labels])},
               else: message
           end)

         result = if state.mode == :timeout, do: {:error, :timeout}, else: :ok
         {result, %{state | messages: messages, restores: state.restores ++ [ids]}}
       end)
     end}
  end
end
