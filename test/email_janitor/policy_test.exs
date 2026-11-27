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
    if Process.get(:fail_settlement, false) do
      {:error, :unavailable}
    else
      ids =
        case result do
          {:confirmed, ids} -> ids
          {:reconciled, ids, _} -> ids
          :unresolved -> []
        end

      record(context, action_id, "settle", ids)
      :ok
    end
  end

  defp record(context, id, kind, ids) do
    Ecto.Adapters.SQL.query!(
      context.scope.repo,
      "INSERT INTO #{context.scope.prefix}.policy_events (action_id, kind, message_ids) VALUES ($1,$2,$3::text[]) ON CONFLICT DO NOTHING",
      [id, kind, ids],
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

  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")

    {:ok, _} =
      Ecto.Adapters.SQL.query(
        TestRepo,
        "CREATE TABLE ej_test_a.policy_events (action_id text, kind text, message_ids text[], PRIMARY KEY(action_id,kind))",
        [],
        log: false
      )

    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    {:ok, proposal} = Reviewer.review([message()], box, MapSet.new(), {TestClassifier, []}, "", 1)

    state =
      start_supervised!({Agent, fn -> %{messages: [message()], contacted: [], calls: []} end})

    %{scope: scope, inbox: box, proposal: proposal, state: state}
  end

  defp execute(ctx, mode) do
    Executor.execute(ctx.scope, ctx.inbox, ctx.proposal, {TestGmail, [state: ctx.state]},
      policy: policy(ctx, mode)
    )
  end

  defp policy(ctx, mode),
    do: %Policy{adapter: TestPolicy, context: %{scope: ctx.scope, mode: mode}}

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
    Process.put(:fail_settlement, true)
    assert {:settlement_pending, id, :done} = execute(ctx, :allow)
    assert %Action{state: :done} = Store.get(ctx.scope, ctx.inbox.id, id)
    Process.put(:fail_settlement, false)

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
end
