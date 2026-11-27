defmodule EmailJanitor.ExecutorTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  import Ecto.Query
  alias EmailJanitor.{Executor, Message, Reviewer, Store, TestClassifier, TestGmail, TestRepo}
  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    {:ok, other_scope} = Scope.new(TestRepo, "ej_test_b")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    {:ok, _} = Store.add_inbox(other_scope, box)
    messages = [message()]
    {:ok, proposal} = Reviewer.review(messages, box, MapSet.new(), {TestClassifier, []}, "", 1)
    state = start_supervised!({Agent, fn -> %{messages: messages, contacted: [], calls: []} end})
    %{scope: scope, other: other_scope, inbox: box, proposal: proposal, state: state}
  end

  defp execute(ctx, opts \\ []) do
    Executor.execute(ctx.scope, ctx.inbox, ctx.proposal, {TestGmail, [state: ctx.state] ++ opts})
  end

  test "durable intent exists before mutation and only INBOX is removed", ctx do
    check = fn ->
      assert [%Action{state: :intent, message_ids: ["message-1"]}] =
               TestRepo.all(Action, prefix: ctx.scope.prefix)
    end

    assert {:done, id} = execute(ctx, before: check)
    assert %Action{state: :done} = Store.get(ctx.scope, ctx.inbox.id, id)
    assert [%Message{labels: ["UNREAD", "IMPORTANT"]}] = Agent.get(ctx.state, & &1.messages)
  end

  test "new reply before commit prevents any mutation or intent", ctx do
    Agent.update(ctx.state, &%{&1 | messages: &1.messages ++ [message(id: "new-reply")]})
    assert {:skip, :proposal_changed} = execute(ctx)
    assert [] == TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [] == Agent.get(ctx.state, & &1.calls)
  end

  test "new correspondence, sent message and draft appearing after review stop execution", ctx do
    Agent.update(ctx.state, &%{&1 | contacted: ["vendor.com"]})
    assert {:skip, :prior_correspondence} = execute(ctx)

    for label <- ["SENT", "DRAFT"] do
      Agent.update(
        ctx.state,
        &%{&1 | contacted: [], messages: [message(labels: ["INBOX", label])]}
      )

      assert {:skip, :proposal_changed} = execute(ctx)
    end

    assert [] == Agent.get(ctx.state, & &1.calls)
  end

  test "stale instruction versions cannot execute", ctx do
    assert {:skip, :proposal_changed} =
             execute(%{ctx | proposal: %{ctx.proposal | instruction_version: 99}})

    assert [] == Agent.get(ctx.state, & &1.calls)
  end

  test "restoring in Gmail never causes duplicate execution", ctx do
    assert {:done, id} = execute(ctx)
    Agent.update(ctx.state, &%{&1 | messages: [message()]})
    :ok = Store.transition(ctx.scope, ctx.inbox.id, id, :done, :restored)
    assert {:skip, :manually_restored} = execute(ctx)
    assert [["message-1"]] == Agent.get(ctx.state, & &1.calls)
  end

  test "ambiguous failures retain durable IDs and never blindly retry even after restoration",
       ctx do
    for mode <- [:timeout_after_apply, :raise_after_apply] do
      case execute(ctx, mode: mode) do
        {:unresolved, id} ->
          assert %Action{state: :unresolved} = Store.get(ctx.scope, ctx.inbox.id, id)

        {:existing, _, :unresolved} ->
          :ok
      end

      Agent.update(ctx.state, &%{&1 | messages: [message()]})
      assert {:existing, _, :unresolved} = execute(ctx)
    end

    assert [["message-1"]] == Agent.get(ctx.state, & &1.calls)
  end

  test "record IDs are scoped by both schema and inbox", ctx do
    assert {:done, id} = execute(ctx)
    assert nil == Store.get(ctx.other, ctx.inbox.id, id)
    assert nil == Store.get(ctx.scope, "other-inbox", id)

    assert {:error, :state_changed} =
             Store.transition(ctx.other, ctx.inbox.id, id, :done, :restored)

    assert MapSet.new() == Store.restored_ids(ctx.other, ctx.inbox.id)
  end

  test "duplicate intents are idempotent", ctx do
    assert {:ok, {:created, first}} = Store.intent(ctx.scope, ctx.inbox.id, ctx.proposal, "100")
    assert {:ok, {:existing, second}} = Store.intent(ctx.scope, ctx.inbox.id, ctx.proposal, "101")
    assert first.id == second.id
    assert TestRepo.aggregate(from(a in Action), :count, prefix: ctx.scope.prefix) == 1
  end

  test "storage has no body fields and persists no email content", ctx do
    assert {:done, _} = execute(ctx)
    records = TestRepo.all(Action, prefix: ctx.scope.prefix)
    refute inspect(records) =~ "Synthetic unsolicited"
    refute :body in Action.__schema__(:fields)

    assert {:error, :invalid_storage_scope} =
             Scope.new(TestRepo, "public\"; DROP SCHEMA public;--")
  end
end
