defmodule EmailJanitor.ConversationLedgerTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  import Ecto.Query
  alias EmailJanitor.{Content, Preferences, Store, TestRepo}
  alias EmailJanitor.Conversation.{Ledger, Outcome, Plan, Receipt, Reference}
  alias EmailJanitor.Store.Scope

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    {:ok, foreign} = Scope.new(TestRepo, "ej_test_b")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    {:ok, _} = Store.add_inbox(foreign, box)
    {:ok, ref} = Reference.new(box.id, "abc123", "abc456", "PRIVATE_SENDER", "PRIVATE_SUBJECT")

    %{
      scope: scope,
      foreign: foreign,
      box: box,
      ref: ref,
      conversation: Ecto.UUID.generate(),
      request: Ecto.UUID.generate()
    }
  end

  defp plan(ref, opts \\ []) do
    %Plan{
      operation: Keyword.get(opts, :operation, :restore),
      references: [ref.token],
      preference_target: Keyword.get(opts, :target, :inbox),
      instruction: Content.new("PRIVATE_DISTILLED_INSTRUCTION"),
      query: Content.new("PRIVATE_SEARCH"),
      reply: Content.new("PRIVATE_REPLY")
    }
  end

  defp reserve(ctx, opts \\ []) do
    Ledger.reserve(
      ctx.scope,
      ctx.box.id,
      ctx.conversation,
      ctx.request,
      plan(ctx.ref, opts),
      [ctx.ref],
      fn -> :ok end
    )
  end

  test "receipt stores only scoped references and enum effects, and duplicate selection is stable",
       ctx do
    assert {:ok, first} = reserve(ctx)
    assert {:ok, ^first} = reserve(ctx)

    assert first.references == [
             %{
               "token" => ctx.ref.token,
               "message_id" => "abc123",
               "thread_id" => "abc456",
               "action_id" => nil
             }
           ]

    serialized =
      TestRepo.all(
        from(r in Receipt,
          select: map(r, [:references, :operation, :preference_target, :results])
        ),
        prefix: ctx.scope.prefix
      )
      |> Jason.encode!()

    for forbidden <-
          ~w(PRIVATE_SENDER PRIVATE_SUBJECT PRIVATE_DISTILLED_INSTRUCTION PRIVATE_SEARCH PRIVATE_REPLY),
        do: refute(serialized =~ forbidden)

    assert nil == Ledger.get(ctx.foreign, ctx.box.id, ctx.conversation, ctx.request)
    assert nil == Ledger.get(ctx.scope, ctx.box.id, Ecto.UUID.generate(), ctx.request)
    assert nil == Ledger.get(ctx.scope, "other-inbox", ctx.conversation, ctx.request)
    assert {:error, :request_conflict} = reserve(ctx, operation: :done)
    assert {:error, :request_conflict} = reserve(%{ctx | conversation: Ecto.UUID.generate()})
  end

  test "selection, guard and mailbox validation are atomic and cannot admit a foreign reference",
       ctx do
    {:ok, foreign_ref} = Reference.new("foreign-inbox", "abc123", "abc456", "Bob", "Hello")

    assert {:error, :invalid_request} =
             Ledger.reserve(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               plan(foreign_ref),
               [foreign_ref],
               fn -> flunk("foreign reference reached guard") end
             )

    assert {:error, :connection_changed} =
             Ledger.reserve(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               plan(ctx.ref),
               [ctx.ref],
               fn -> {:error, :disconnected} end
             )

    assert nil == Ledger.get(ctx.scope, ctx.box.id, ctx.conversation, ctx.request)

    assert {:error, :unknown_inbox} =
             Ledger.reserve(
               ctx.scope,
               "missing",
               ctx.conversation,
               ctx.request,
               plan(ctx.ref),
               [],
               fn -> :ok end
             )
  end

  test "independently replayed effect receipts do not overwrite confirmed or ambiguous results",
       ctx do
    {:ok, _} = reserve(ctx)
    effect_id = Ecto.UUID.generate()

    assert {:ok, %{preference_status: :updated}} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :updated,
               1
             )

    assert {:ok, %{preference_status: :updated}} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :failed,
               nil
             )

    assert {:ok, first} =
             Ledger.record_result(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               ctx.ref.token,
               "unresolved",
               effect_id
             )

    assert {:ok, ^first} =
             Ledger.record_result(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               ctx.ref.token,
               "restored",
               Ecto.UUID.generate()
             )

    assert {:error, :invalid_reference} =
             Ledger.record_result(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               "invented",
               "done",
               effect_id
             )

    assert {:ok, %{completed: true}} =
             Ledger.complete(ctx.scope, ctx.box.id, ctx.conversation, ctx.request)
  end

  test "replies report effects and preserve uncertainty, rather than the model's proposed success",
       ctx do
    {:ok, receipt} = reserve(ctx)
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.box.id)
    receipt = %{receipt | results: [%{"status" => "unresolved"}], preference_status: :failed}
    reply = Outcome.render(receipt, snapshot) |> Content.read()
    assert reply =~ "uncertain"
    assert reply =~ "could not update"
    refute reply =~ "returned"
    refute reply =~ "PRIVATE_REPLY"
    later = %{receipt | results: [], preference_status: :updated, preference_revision: 1}

    assert Outcome.render(later, %{snapshot | local_revision: 2}) |> Content.read() =~
             "since been changed"
  end

  test "seven-day context retention expires without any new conversation write", ctx do
    {:ok, _} = reserve(ctx)
    assert %Receipt{} = Ledger.latest(ctx.scope, ctx.box.id, ctx.conversation)
    future = DateTime.add(DateTime.utc_now(), 604_801)
    assert {1, nil} = Ledger.purge(ctx.scope, future)
    assert nil == Ledger.latest(ctx.scope, ctx.box.id, ctx.conversation)
  end
end
