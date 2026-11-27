defmodule EmailJanitor.TestPolicy do
  @behaviour EmailJanitor.Policy

  def reserve(context, _inbox, action_id, ids, _now) do
    if !context.scope.repo.in_transaction?(), do: raise("Admission must be transactional")
    record(context, action_id, "reserve", ids)

    case context.mode do
      :block -> {:blocked, :upgrade_required}
      :error -> {:error, :unavailable}
      :raise -> raise "PRIVATE_POLICY_SENTINEL"
      _ -> :ok
    end
  end

  def settle(context, _inbox, action_id, result) do
    if observer = Map.get(context, :observer),
      do: send(observer, {:policy_settlement, action_id, result})

    failed =
      case Map.get(context, :control) do
        nil -> false
        control -> Agent.get(control, & &1.fail)
      end

    if failed do
      {:error, :unavailable}
    else
      {ids, rest} =
        case result do
          {:confirmed, ids} -> {ids, []}
          {:reconciled, ids, rest} -> {ids, rest}
          :unresolved -> {[], []}
        end

      record(context, action_id, "settle", ids, rest)
      :ok
    end
  end

  def retire_candidate(context, _inbox, id, ids) do
    if context.mode == :retire_error do
      {:error, :unavailable}
    else
      record(context, id, "retire", ids)

      Ecto.Adapters.SQL.query!(
        context.scope.repo,
        "DELETE FROM #{context.scope.prefix}.policy_events WHERE action_id=$1 AND kind='reserve'",
        [id],
        log: false
      )

      :ok
    end
  end

  defp record(context, id, kind, ids, rest \\ []) do
    Ecto.Adapters.SQL.query!(
      context.scope.repo,
      "INSERT INTO #{context.scope.prefix}.policy_events (action_id, kind, message_ids, not_applied_ids) VALUES ($1,$2,$3::text[],$4::text[]) ON CONFLICT(action_id,kind) DO UPDATE SET message_ids=EXCLUDED.message_ids, not_applied_ids=EXCLUDED.not_applied_ids",
      [id, kind, ids, rest],
      log: false
    )
  end
end

defmodule EmailJanitor.PolicyTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Executor,
    Policy,
    Reviewer,
    Store,
    TestClassifier,
    TestGmail,
    TestPolicy,
    TestRepo
  }

  alias EmailJanitor.Store.{Action, Candidate, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        TestRepo,
        "CREATE TABLE ej_test_a.policy_events (action_id text, kind text, message_ids text[], not_applied_ids text[], PRIMARY KEY(action_id,kind))",
        [],
        log: false
      )

    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    {:ok, proposal} = Reviewer.review([message()], box, MapSet.new(), {TestClassifier, []}, "", 1)

    state =
      start_supervised!({Agent, fn -> %{messages: [message()], contacted: [], calls: []} end})

    control = start_supervised!({Agent, fn -> %{fail: false} end}, id: :policy_control)
    %{scope: scope, inbox: box, proposal: proposal, state: state, control: control}
  end

  defp execute(ctx, mode, gmail_opts \\ []) do
    Executor.execute(
      ctx.scope,
      ctx.inbox,
      ctx.proposal,
      {TestGmail, [state: ctx.state] ++ gmail_opts},
      policy: policy(ctx, mode)
    )
  end

  defp policy(ctx, mode),
    do: %Policy{
      adapter: TestPolicy,
      context: %{scope: ctx.scope, mode: mode, control: ctx.control, observer: self()}
    }

  defp events do
    Ecto.Adapters.SQL.query!(
      TestRepo,
      "SELECT kind,message_ids FROM ej_test_a.policy_events ORDER BY kind",
      [],
      log: false
    ).rows
  end

  test "blocked policy commits pending metadata without creating a Gmail intent", ctx do
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [["reserve", ["message-1"]]] = events()
    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "repeated blocked notifications retain one candidate and promote its ID on admission",
       ctx do
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: ^id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    assert [["reserve", ["message-1"]]] = events()
    assert {:done, ^id} = execute(ctx, :allow)
    assert [] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    assert %Action{id: ^id} = Store.get(ctx.scope, ctx.inbox.id, id)
    assert [["message-1"]] = Agent.get(ctx.state, & &1.calls)
  end

  test "a cancelled admitted candidate never lends its ID to a new reservation", ctx do
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert {:ok, {:created, %Action{id: ^id}}} =
             Store.intent(ctx.scope, ctx.inbox.id, ctx.proposal, "100",
               policy: policy(ctx, :allow)
             )

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "UPDATE #{ctx.scope.prefix}.actions SET state='cancelled' WHERE id=$1::uuid",
      [Ecto.UUID.dump!(id)],
      log: false
    )

    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: next}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    refute next == id
  end

  test "large blocked message sets retain a stable identity without an oversized database index",
       ctx do
    messages = for _ <- 1..512, do: message(id: Ecto.UUID.generate() |> String.replace("-", ""))
    Agent.update(ctx.state, &%{&1 | messages: messages})

    {:ok, proposal} =
      Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

    ctx = %{ctx | proposal: proposal}
    assert {:blocked, :upgrade_required} = execute(ctx, :block)

    assert [%Candidate{id: id, message_ids: ids}] =
             TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert length(ids) == 512
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: ^id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "a growing blocked thread retires the superseded proposal at core and host", ctx do
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: old}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    messages = [message(), message(id: "message-2")]
    Agent.update(ctx.state, &%{&1 | messages: messages})

    {:ok, proposal} =
      Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

    ctx = %{ctx | proposal: proposal}
    assert {:blocked, :upgrade_required} = execute(ctx, :block)

    assert [%Candidate{id: current, message_ids: ["message-1", "message-2"]}] =
             TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    refute current == old

    assert %{rows: [[^old, "retire"], [^current, "reserve"]]} =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT action_id,kind FROM #{ctx.scope.prefix}.policy_events ORDER BY kind DESC",
               [],
               log: false
             )

    assert {:done, ^current} = execute(ctx, :allow)
    assert [] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    assert [["message-1", "message-2"]] = Agent.get(ctx.state, & &1.calls)
  end

  test "candidate retirement failure rolls back admission and all host metadata", ctx do
    assert {:blocked, :upgrade_required} = execute(ctx, :block)
    assert [%Candidate{id: old}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    messages = [message(), message(id: "message-2")]
    Agent.update(ctx.state, &%{&1 | messages: messages})

    {:ok, proposal} =
      Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

    assert {:error, :policy_unavailable} = execute(%{ctx | proposal: proposal}, :retire_error)
    assert [%Candidate{id: ^old}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [["reserve", ["message-1"]]] = events()
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  for mode <- [:error, :raise] do
    test "#{mode} admission rolls back metadata and never changes Gmail", ctx do
      assert {:error, :policy_unavailable} = execute(ctx, unquote(mode))
      assert [] = events()
      assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
      assert [] = Agent.get(ctx.state, & &1.calls)
    end
  end

  test "successful mutation settles the same stable action ID", ctx do
    assert {:done, id} = execute(ctx, :allow)
    assert %Action{state: :done} = Store.get(ctx.scope, ctx.inbox.id, id)
    assert [["reserve", ["message-1"]], ["settle", ["message-1"]]] = events()

    assert %{rows: [[^id], [^id]]} =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT action_id FROM ej_test_a.policy_events ORDER BY kind",
               [],
               log: false
             )
  end

  test "failed settlement retries from durable outcomes without another Gmail call", ctx do
    Agent.update(ctx.control, &%{&1 | fail: true})
    assert {:settlement_pending, id, :done} = execute(ctx, :allow)
    assert %Action{state: :done} = Store.get(ctx.scope, ctx.inbox.id, id)
    Agent.update(ctx.control, &%{&1 | fail: false})

    assert {:existing, ^id, :done} =
             Executor.settle_action(ctx.scope, ctx.inbox, id, policy: policy(ctx, :allow))

    assert [["message-1"]] = Agent.get(ctx.state, & &1.calls)
    assert [["reserve", ["message-1"]], ["settle", ["message-1"]]] = events()
  end

  test "settlement retries cannot cross inbox or schema boundaries", ctx do
    assert {:done, id} = execute(ctx, :allow)
    {:ok, other} = Scope.new(TestRepo, "ej_test_b")

    assert {:error, :unknown_action} =
             Executor.settle_action(other, ctx.inbox, id, policy: policy(ctx, :allow))

    assert {:error, :unknown_action} =
             Executor.settle_action(ctx.scope, %{ctx.inbox | id: "other"}, id,
               policy: policy(ctx, :allow)
             )
  end

  test "Gmail ambiguity settles unresolved under the injected policy", ctx do
    assert {:unresolved, id} = execute(ctx, :allow, mode: :timeout_after_apply)
    assert_received {:policy_settlement, ^id, :unresolved}
    assert %Action{state: :unresolved} = Store.get(ctx.scope, ctx.inbox.id, id)
  end

  for fail_settlement <- [false, true] do
    test "mixed history stays blocked until all IDs are observed (failure=#{fail_settlement})",
         ctx do
      messages = [message(id: "message-1"), message(id: "message-2")]
      Agent.update(ctx.state, &%{&1 | messages: messages})

      {:ok, proposal} =
        Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

      ctx = %{ctx | proposal: proposal}
      assert {:unresolved, id} = execute(ctx, :allow, mode: :timeout_after_apply)
      assert_received {:policy_settlement, ^id, :unresolved}
      Agent.update(ctx.control, &%{&1 | fail: unquote(fail_settlement)})

      history = %{
        complete?: true,
        started_at: DateTime.utc_now(),
        events: [
          %{history_id: "101", message_id: "message-1", event: :inbox_removed},
          %{history_id: "102", message_id: "message-1", event: :inbox_added}
        ]
      }

      assert {:error, :dispatch_outcome_unknown} =
               Executor.reconcile(ctx.scope, ctx.inbox, id, history, policy: policy(ctx, :allow))

      refute_received {:policy_settlement, ^id, {:reconciled, _, _}}

      history = %{
        history
        | events:
            history.events ++
              [%{history_id: "103", message_id: "message-2", event: :inbox_removed}]
      }

      result = Executor.reconcile(ctx.scope, ctx.inbox, id, history, policy: policy(ctx, :allow))
      assert_received {:policy_settlement, ^id, {:reconciled, ["message-1", "message-2"], []}}

      if unquote(fail_settlement),
        do: assert(result == {:settlement_pending, id, :restored}),
        else: assert(match?({:ok, {:restored, _}}, result))

      Agent.update(ctx.control, &%{&1 | fail: false})

      assert {:existing, ^id, :restored} =
               Executor.settle_action(ctx.scope, ctx.inbox, id, policy: policy(ctx, :allow))

      assert_received {:policy_settlement, ^id, {:reconciled, ["message-1", "message-2"], []}}
      assert [["message-1", "message-2"]] = Agent.get(ctx.state, & &1.calls)

      assert %{rows: [[["message-1", "message-2"], []]]} =
               Ecto.Adapters.SQL.query!(
                 TestRepo,
                 "SELECT message_ids,not_applied_ids FROM ej_test_a.policy_events WHERE kind='settle'",
                 [],
                 log: false
               )
    end
  end
end
