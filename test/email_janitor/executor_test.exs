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

  for mode <- [
        :timeout_after_apply,
        :raise_after_apply,
        :throw_after_apply,
        :exit_after_apply,
        :error_without_apply
      ] do
    test "#{mode} retains an intent and never blindly retries", ctx do
      assert {:unresolved, id} = execute(ctx, mode: unquote(mode))
      assert %Action{state: :unresolved} = Store.get(ctx.scope, ctx.inbox.id, id)
      Agent.update(ctx.state, &%{&1 | messages: [message()]})
      assert {:existing, _, :unresolved} = execute(ctx)
      assert [["message-1"]] == Agent.get(ctx.state, & &1.calls)
    end
  end

  for mode <- [:timeout_after_apply, :ok] do
    test "#{mode} cannot re-archive restored mail with changed labels or instructions", ctx do
      assert elem(execute(ctx, mode: unquote(mode)), 0) in [:done, :unresolved]
      changed = message(labels: ["INBOX", "IMPORTANT"])
      Agent.update(ctx.state, &%{&1 | messages: [changed]})

      {:ok, fresh} =
        Reviewer.review([changed], ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

      assert {:existing, _, _} = execute(%{ctx | proposal: fresh})

      TestRepo.update_all(EmailJanitor.Store.Mailbox, [set: [instruction_version: 2]],
        prefix: ctx.scope.prefix
      )

      {:ok, fresh} =
        Reviewer.review(
          [changed],
          ctx.inbox,
          MapSet.new(),
          {TestClassifier, []},
          "New preference.",
          2
        )

      assert {:existing, _, _} = execute(%{ctx | proposal: fresh})
      assert [["message-1"]] == Agent.get(ctx.state, & &1.calls)
      assert [^changed] = Agent.get(ctx.state, & &1.messages)
    end
  end

  test "a cancelled intent can be retried only after fresh safeguards", ctx do
    assert {:unresolved, id} = execute(ctx, mode: :error_without_apply)

    assert {:ok, {:cancelled, _}} =
             Store.reconcile(ctx.scope, ctx.inbox.id, id, %{complete?: true, events: []})

    assert {:done, new_id} = execute(ctx)
    refute id == new_id
  end

  test "mixed recovery never cancels restored IDs to retry an unseen batch member", ctx do
    messages = [message(id: "message-1"), message(id: "message-2")]
    Agent.update(ctx.state, &%{&1 | messages: messages})

    {:ok, proposal} =
      Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

    ctx = %{ctx | proposal: proposal}
    assert {:unresolved, id} = execute(ctx, mode: :timeout_after_apply)

    history = %{
      complete?: true,
      events: [
        %{history_id: "101", message_id: "message-1", event: :inbox_removed},
        %{history_id: "102", message_id: "message-1", event: :inbox_added}
      ]
    }

    assert {:ok, {:restored, %{retry_ids: ["message-2"]}}} =
             Store.reconcile(ctx.scope, ctx.inbox.id, id, history)

    assert %Action{applied_message_ids: ["message-1"], restored_message_ids: ["message-1"]} =
             Store.get(ctx.scope, ctx.inbox.id, id)

    Agent.update(ctx.state, &%{&1 | messages: messages})
    assert {:skip, :manually_restored} = execute(ctx)
    assert [["message-1", "message-2"]] == Agent.get(ctx.state, & &1.calls)
  end

  test "incomplete history preserves the uncertain intent", ctx do
    assert {:unresolved, id} = execute(ctx, mode: :error_without_apply)

    assert {:error, :incomplete_history} =
             Store.reconcile(ctx.scope, ctx.inbox.id, id, %{complete?: false, events: []})

    assert %Action{state: :unresolved} = Store.get(ctx.scope, ctx.inbox.id, id)
    assert {:existing, _, :unresolved} = execute(ctx)
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
    assert second.history_id == "100"
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
