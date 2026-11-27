defmodule EmailJanitor.RacePolicy do
  @behaviour EmailJanitor.Policy
  def retire_candidate(context, inbox, id, ids),
    do: EmailJanitor.TestPolicy.retire_candidate(context, inbox, id, ids)

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
  require Ecto.Query
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

                   send(parent, {:prepared_recovery, action.id, self()})
                   raise "SYNTHETIC_EXECUTOR_FAILURE"
                 end)
               end)

      assert_receive {:prepared_recovery, id, owner}
      owner_monitor = Process.monitor(owner)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
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

    assert Enum.all?(results, fn
             {:ok, {:blocked, :upgrade_required}} -> true
             {:ok, {:error, :proposal_changed}} -> true
             _ -> false
           end)

    assert {:ok, {:blocked, :upgrade_required}} in results

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

  for newer_ids <- [["message-1"], ["message-1", "message-2"]] do
    test "an older admission cannot bypass newer overlapping #{inspect(newer_ids)}", ctx do
      parent = self()

      hook = fn ->
        send(parent, {:old_review_paused, self()})

        receive do
          :resume_old_review -> :ok
        after
          5_000 -> raise "Synthetic admission barrier timed out"
        end
      end

      {old, monitor} =
        spawn_monitor(fn ->
          result =
            database(fn ->
              Executor.execute(
                ctx.scope,
                ctx.inbox,
                ctx.proposal,
                {TestGmail, [state: ctx.state, history_hook: hook]},
                policy: ctx.policy
              )
            end)

          send(parent, {:old_admission, result})
        end)

      on_exit(fn -> Process.exit(old, :kill) end)
      assert_receive {:old_review_paused, owner}, 5_000
      on_exit(fn -> Process.exit(owner, :kill) end)

      messages = Enum.map(unquote(newer_ids), &message(id: &1))
      Agent.update(ctx.state, &%{&1 | messages: messages})

      {:ok, newer} =
        Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

      mode = if length(messages) > 1, do: :block_batch, else: :block
      blocked = %{ctx.policy | context: %{ctx.policy.context | mode: mode}}

      assert {:blocked, :upgrade_required} =
               database(fn ->
                 Executor.execute(ctx.scope, ctx.inbox, newer, {TestGmail, [state: ctx.state]},
                   policy: blocked
                 )
               end)

      [candidate] =
        database(fn ->
          TestRepo.all(
            Ecto.Query.from(c in EmailJanitor.Store.Candidate,
              where: c.inbox_id == ^ctx.inbox.id
            ),
            prefix: ctx.scope.prefix
          )
        end)

      send(owner, :resume_old_review)
      assert_receive {:old_admission, {:error, :proposal_changed}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^old, :normal}, 5_000
      assert [] = Agent.get(ctx.state, & &1.calls)

      assert %{rows: [[1, 0]]} =
               database(fn ->
                 Ecto.Adapters.SQL.query!(
                   TestRepo,
                   "SELECT (SELECT count(*) FROM #{ctx.scope.prefix}.policy_events WHERE action_id=$1 AND kind='reserve'), (SELECT count(*) FROM #{ctx.scope.prefix}.actions WHERE inbox_id=$2)",
                   [candidate.id, ctx.inbox.id],
                   log: false
                 )
               end)

      assert {:done, id} =
               database(fn ->
                 Executor.execute(ctx.scope, ctx.inbox, newer, {TestGmail, [state: ctx.state]},
                   policy: ctx.policy
                 )
               end)

      assert id == candidate.id
      assert [unquote(newer_ids)] == Agent.get(ctx.state, & &1.calls)
    end
  end

  for latest <- [:blocked, :keep], phase <- [:in_flight, :cached_review] do
    test "a newer #{latest} evaluation fences an older Done (#{phase})", ctx do
      messages = [message(), message(id: "message-2")]
      Agent.update(ctx.state, &%{&1 | messages: messages})
      parent = self()
      ids = ["message-1", "message-2"]

      assert {:ok, old} =
               database(fn ->
                 Executor.review(
                   ctx.scope,
                   ctx.inbox,
                   "thread-1",
                   {TestGmail, [state: ctx.state]},
                   {EmailJanitor.TargetClassifier, []},
                   "",
                   1,
                   cleanup_target_ids: ["message-1"]
                 )
               end)

      paused = fn ->
        send(parent, {:evaluated_pause, self()})

        receive do
          :continue_evaluated -> :ok
        after
          5_000 -> raise "Synthetic evaluation barrier timed out"
        end
      end

      running =
        if unquote(phase) == :in_flight do
          {pid, monitor} =
            spawn_monitor(fn ->
              result =
                database(fn ->
                  Executor.execute(
                    ctx.scope,
                    ctx.inbox,
                    old,
                    {TestGmail, [state: ctx.state, history_hook: paused]}
                  )
                end)

              send(parent, {:evaluated_old_result, result})
            end)

          on_exit(fn -> Process.exit(pid, :kill) end)
          assert_receive {:evaluated_pause, owner}, 5_000
          on_exit(fn -> Process.exit(owner, :kill) end)
          {pid, monitor, owner}
        end

      keep_ids = if unquote(latest) == :keep, do: ids, else: ["message-1"]

      newer =
        database(fn ->
          Executor.review(
            ctx.scope,
            ctx.inbox,
            "thread-1",
            {TestGmail, [state: ctx.state]},
            {EmailJanitor.TargetClassifier, [keep_ids: keep_ids]},
            "",
            1,
            cleanup_target_ids: ids
          )
        end)

      if unquote(latest) == :blocked do
        assert {:ok, newer} = newer
        assert newer.message_ids == ["message-2"]

        blocked = %Policy{
          adapter: EmailJanitor.TargetPolicy,
          context: %{scope: ctx.scope, mode: :block}
        }

        assert {:blocked, :upgrade_required} =
                 database(fn ->
                   Executor.execute(ctx.scope, ctx.inbox, newer, {TestGmail, [state: ctx.state]},
                     policy: blocked
                   )
                 end)
      else
        assert {:keep, :classifier_kept} = newer
      end

      if running do
        {pid, monitor, owner} = running
        send(owner, :continue_evaluated)
        assert_receive {:evaluated_old_result, {:error, :proposal_changed}}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      else
        assert {:error, :proposal_changed} =
                 database(fn ->
                   Executor.execute(ctx.scope, ctx.inbox, old, {TestGmail, [state: ctx.state]})
                 end)
      end

      assert [] = Agent.get(ctx.state, & &1.calls)

      # New work can proceed after a genuinely fresh review of the same labels.
      assert {:ok, fresh} =
               database(fn ->
                 Executor.review(
                   ctx.scope,
                   ctx.inbox,
                   "thread-1",
                   {TestGmail, [state: ctx.state]},
                   {EmailJanitor.TargetClassifier, []},
                   "",
                   1,
                   cleanup_target_ids: ["message-1"]
                 )
               end)

      assert {:done, _} =
               database(fn ->
                 Executor.execute(ctx.scope, ctx.inbox, fresh, {TestGmail, [state: ctx.state]})
               end)

      assert [["message-1"]] = Agent.get(ctx.state, & &1.calls)
    end
  end

  for phase <- [:in_flight, :cached_review] do
    test "an existing unresolved action preserves a newer Keep fence (#{phase})", ctx do
      messages = [message(), message(id: "message-2")]
      Agent.update(ctx.state, &%{&1 | messages: messages})
      parent = self()

      review = fn targets, keep ->
        database(fn ->
          Executor.review(
            ctx.scope,
            ctx.inbox,
            "thread-1",
            {TestGmail, [state: ctx.state]},
            {EmailJanitor.TargetClassifier, [keep_ids: keep]},
            "",
            1,
            cleanup_target_ids: targets
          )
        end)
      end

      assert {:ok, action_proposal} = review.(["message-1"], [])

      assert {:unresolved, action_id} =
               database(fn ->
                 Executor.execute(
                   ctx.scope,
                   ctx.inbox,
                   action_proposal,
                   {TestGmail, [state: ctx.state, mode: :error_without_apply]}
                 )
               end)

      assert {:ok, old} = review.(["message-2"], [])

      running =
        if unquote(phase) == :in_flight do
          {pid, monitor} =
            spawn_monitor(fn ->
              result =
                database(fn ->
                  Executor.execute(
                    ctx.scope,
                    ctx.inbox,
                    old,
                    {TestGmail,
                     [
                       state: ctx.state,
                       history_hook: fn ->
                         send(parent, {:existing_pause, self()})

                         receive do
                           :continue_existing -> :ok
                         after
                           5_000 -> raise "Synthetic existing-action barrier timed out"
                         end
                       end
                     ]}
                  )
                end)

              send(parent, {:existing_old_result, result})
            end)

          on_exit(fn -> Process.exit(pid, :kill) end)
          assert_receive {:existing_pause, owner}, 5_000
          on_exit(fn -> Process.exit(owner, :kill) end)
          {pid, monitor, owner}
        end

      assert {:ok, newer} = review.(["message-1", "message-2"], ["message-2"])

      assert {:existing, ^action_id, :unresolved} =
               database(fn ->
                 Executor.execute(ctx.scope, ctx.inbox, newer, {TestGmail, [state: ctx.state]})
               end)

      if running do
        {pid, monitor, owner} = running
        send(owner, :continue_existing)
        assert_receive {:existing_old_result, {:error, :proposal_changed}}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      else
        assert {:error, :proposal_changed} =
                 database(fn ->
                   Executor.execute(ctx.scope, ctx.inbox, old, {TestGmail, [state: ctx.state]})
                 end)
      end

      fence = fn ->
        database(fn ->
          TestRepo.get_by!(
            Store.ReviewFence,
            [inbox_id: ctx.inbox.id, message_id: "message-2"],
            prefix: ctx.scope.prefix
          )
        end).reviewed_at
      end

      accepted_at = fence.()
      # A cached retry can settle its original action without refreshing the
      # accepted timestamp for any newer evaluation.
      assert {:existing, ^action_id, :unresolved} =
               database(fn ->
                 Executor.execute(ctx.scope, ctx.inbox, newer, {TestGmail, [state: ctx.state]})
               end)

      assert accepted_at == fence.()
      assert [["message-1"]] == Agent.get(ctx.state, & &1.calls)
    end
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
