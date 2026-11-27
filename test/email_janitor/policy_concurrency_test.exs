defmodule EmailJanitor.RacePolicy do
  @behaviour EmailJanitor.Policy
  def reserve(context, inbox, action, ids, now),
    do: EmailJanitor.TestPolicy.reserve(context, inbox, action, ids, now)

  def settle(context, inbox, action, result) do
    true = context.scope.repo.in_transaction?()
    send(context.observer, {:settlement_paused, self(), action, result})

    receive do
      :release_settlement -> EmailJanitor.TestPolicy.settle(context, inbox, action, result)
    after
      5_000 -> {:error, :test_timeout}
    end
  end
end

defmodule EmailJanitor.PolicyConcurrencyTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Executor,
    Inbox,
    Policy,
    RacePolicy,
    Reviewer,
    Store,
    TestClassifier,
    TestGmail,
    TestPolicy,
    TestRepo
  }

  alias EmailJanitor.Store.Scope

  defp database(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  setup do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    {:ok, box} = Inbox.new("policy-" <> suffix, "owner-" <> suffix <> "@acme.com")
    {:ok, scope} = Scope.new(TestRepo, "ej_policy_concurrency")

    database(fn ->
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "CREATE TABLE IF NOT EXISTS #{scope.prefix}.policy_events (action_id text, kind text, message_ids text[], not_applied_ids text[], PRIMARY KEY(action_id,kind))",
        [],
        log: false
      )

      {:ok, _} = Store.add_inbox(scope, box)
    end)

    {:ok, proposal} = Reviewer.review([message()], box, MapSet.new(), {TestClassifier, []}, "", 1)

    state =
      start_supervised!({Agent, fn -> %{messages: [message()], contacted: [], calls: []} end})

    policy = %Policy{adapter: TestPolicy, context: %{scope: scope, mode: :allow}}
    %{scope: scope, inbox: box, proposal: proposal, state: state, policy: policy}
  end

  for dispatched <- [false, true] do
    test "recovery settles #{if dispatched, do: "sent ambiguity without releasing slots", else: "prepared non-application"}",
         ctx do
      parent = self()

      assert {:error, :executor_unavailable} =
               EmailJanitor.Owner.run(fn ->
                 database(fn ->
                   {:ok, {:created, action}} =
                     Store.intent(ctx.scope, ctx.inbox.id, ctx.proposal, "100",
                       policy: ctx.policy
                     )

                   if unquote(dispatched),
                     do:
                       :ok =
                         Store.begin_dispatch(
                           ctx.scope,
                           ctx.inbox.id,
                           action.id,
                           action.owner_token
                         )

                   send(parent, {:prepared_recovery, action.id})
                   raise "SYNTHETIC_EXECUTOR_FAILURE"
                 end)
               end)

      assert_receive {:prepared_recovery, id}
      state = if unquote(dispatched), do: :unresolved, else: :cancelled

      assert {:ok, {^state, _}} =
               database(fn -> Executor.recover(ctx.scope, ctx.inbox, id, policy: ctx.policy) end)

      not_applied = if unquote(dispatched), do: [], else: ["message-1"]

      assert %{rows: [[[], ^not_applied]]} =
               database(fn ->
                 Ecto.Adapters.SQL.query!(
                   TestRepo,
                   "SELECT message_ids,not_applied_ids FROM #{ctx.scope.prefix}.policy_events WHERE action_id=$1 AND kind='settle'",
                   [id],
                   log: false
                 )
               end)

      assert [] = Agent.get(ctx.state, & &1.calls)
    end
  end

  test "concurrent blocked notifications create one durable candidate identity", ctx do
    blocked = %{ctx.policy | context: %{ctx.policy.context | mode: :block}}

    results =
      1..6
      |> Task.async_stream(
        fn _ ->
          database(fn ->
            Executor.execute(ctx.scope, ctx.inbox, ctx.proposal, {TestGmail, [state: ctx.state]},
              policy: blocked
            )
          end)
        end,
        max_concurrency: 6,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, {:blocked, :upgrade_required}}))

    assert %{rows: [[1, 1]]} =
             database(fn ->
               Ecto.Adapters.SQL.query!(
                 TestRepo,
                 "SELECT (SELECT count(*) FROM #{ctx.scope.prefix}.action_candidates WHERE inbox_id=$1), (SELECT count(*) FROM #{ctx.scope.prefix}.policy_events WHERE action_id IN (SELECT id::text FROM #{ctx.scope.prefix}.action_candidates WHERE inbox_id=$1))",
                 [ctx.inbox.id],
                 log: false
               )
             end)

    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  for entry <- [:settle_action, :execute] do
    test "#{entry} cannot overwrite terminal reconciliation with stale unresolved settlement",
         ctx do
      assert {:unresolved, id} =
               database(fn ->
                 Executor.execute(
                   ctx.scope,
                   ctx.inbox,
                   ctx.proposal,
                   {TestGmail, [state: ctx.state, mode: :timeout_after_apply]},
                   policy: ctx.policy
                 )
               end)

      Agent.update(ctx.state, &%{&1 | messages: [message()]})
      parent = self()

      paused = %Policy{
        adapter: RacePolicy,
        context: %{scope: ctx.scope, mode: :allow, observer: parent}
      }

      {retry, retry_monitor} =
        spawn_monitor(fn ->
          result =
            database(fn ->
              case unquote(entry) do
                :settle_action ->
                  Executor.settle_action(ctx.scope, ctx.inbox, id, policy: paused)

                :execute ->
                  Executor.execute(
                    ctx.scope,
                    ctx.inbox,
                    ctx.proposal,
                    {TestGmail, [state: ctx.state]},
                    policy: paused
                  )
              end
            end)

          send(parent, {:retry_result, result})
        end)

      on_exit(fn -> Process.exit(retry, :kill) end)
      assert_receive {:settlement_paused, settlement_owner, ^id, :unresolved}, 5_000
      on_exit(fn -> Process.exit(settlement_owner, :kill) end)

      {reconcile, reconcile_monitor} =
        spawn_monitor(fn ->
          history = %{
            complete?: true,
            started_at: DateTime.utc_now(),
            events: [%{history_id: "101", message_id: "message-1", event: :inbox_removed}]
          }

          result =
            database(fn ->
              Executor.reconcile(ctx.scope, ctx.inbox, id, history, policy: ctx.policy)
            end)

          send(parent, {:reconcile_result, result})
        end)

      on_exit(fn -> Process.exit(reconcile, :kill) end)
      assert wait_for_lock(ctx.scope.prefix)
      refute_received {:reconcile_result, _}
      send(settlement_owner, :release_settlement)
      assert_receive {:retry_result, {:existing, ^id, :unresolved}}, 5_000
      assert_receive {:reconcile_result, {:ok, {:done, _}}}, 5_000
      assert_receive {:DOWN, ^retry_monitor, :process, ^retry, :normal}, 5_000
      assert_receive {:DOWN, ^reconcile_monitor, :process, ^reconcile, :normal}, 5_000

      assert %{rows: [[["message-1"], []]]} =
               database(fn ->
                 Ecto.Adapters.SQL.query!(
                   TestRepo,
                   "SELECT message_ids,not_applied_ids FROM #{ctx.scope.prefix}.policy_events WHERE action_id=$1 AND kind='settle'",
                   [id],
                   log: false
                 )
               end)

      assert [["message-1"]] = Agent.get(ctx.state, & &1.calls)
    end
  end

  defp wait_for_lock(prefix, tries \\ 100)
  defp wait_for_lock(_, 0), do: false

  defp wait_for_lock(prefix, tries) do
    %{rows: [[waiting]]} =
      database(fn ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE $1)",
          ["%" <> prefix <> "%FOR UPDATE%"],
          log: false
        )
      end)

    if waiting,
      do: true,
      else:
        (
          Process.sleep(10)
          wait_for_lock(prefix, tries - 1)
        )
  end
end
