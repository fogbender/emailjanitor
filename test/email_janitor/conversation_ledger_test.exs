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
      search_complete: true,
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
               %Plan{operation: :answer, references: [], preference_target: :none},
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

  test "effect selection is pinned independently of read-only conversation context", ctx do
    {:ok, other} = Reference.new(ctx.box.id, "abc999", "def999", "Other", "Other email")
    request = plan(ctx.ref)

    assert {:ok, receipt} =
             Ledger.reserve(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               request,
               [other, ctx.ref],
               fn -> :ok end
             )

    assert length(receipt.context_references) == 2
    assert Enum.map(receipt.references, & &1["token"]) == [ctx.ref.token]

    assert {:error, :invalid_request} =
             Ledger.reserve(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               Ecto.UUID.generate(),
               request,
               [ctx.ref, ctx.ref],
               fn -> :ok end
             )

    answer = %Plan{operation: :answer, references: [], preference_target: :none}

    assert {:ok, empty} =
             Ledger.reserve(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               Ecto.UUID.generate(),
               answer,
               [other],
               fn -> :ok end
             )

    assert empty.references == []
    assert length(empty.context_references) == 1

    assert {:error, :invalid_request} =
             Ledger.reserve(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               Ecto.UUID.generate(),
               %{request | search_complete: false},
               [ctx.ref],
               fn -> :ok end
             )
  end

  test "recorded outcomes must match the reserved operation and preference target", ctx do
    {:ok, _} = reserve(ctx)

    assert {:error, :invalid_effect} =
             Ledger.record_result(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               ctx.ref.token,
               "done",
               Ecto.UUID.generate()
             )

    assert {:error, :invalid_preference_result} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :updated,
               nil
             )

    assert {:error, :effects_pending} =
             Ledger.complete(ctx.scope, ctx.box.id, ctx.conversation, ctx.request)

    answer = %Plan{operation: :answer, references: [], preference_target: :none}
    id = Ecto.UUID.generate()

    {:ok, _} =
      Ledger.reserve(ctx.scope, ctx.box.id, ctx.conversation, id, answer, [], fn -> :ok end)

    assert {:error, :invalid_preference_result} =
             Ledger.record_preference(ctx.scope, ctx.box.id, ctx.conversation, id, :updated, 1)
  end

  test "unrecorded effects stay uncertain and a foreign snapshot cannot make completion claims",
       ctx do
    {:ok, receipt} = reserve(ctx)
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.box.id)
    text = Outcome.render(receipt, snapshot) |> Content.read()
    assert text =~ "uncertain"
    assert text =~ "still being verified"
    refute text =~ "No email or instruction changes"

    for other <- [
          %{snapshot | inbox_id: "foreign"},
          %{snapshot | scope_prefix: ctx.foreign.prefix}
        ] do
      assert Outcome.render(receipt, other) |> Content.read() =~ "could not verify"
    end
  end

  test "the seven-day window applies to get, writes and re-reservation before a purge job runs",
       ctx do
    {:ok, original} = reserve(ctx)
    past = DateTime.add(DateTime.utc_now(), -604_801)

    TestRepo.update_all(
      from(r in Receipt, where: r.id == ^ctx.request),
      [set: [inserted_at: past]],
      prefix: ctx.scope.prefix
    )

    assert nil == Ledger.get(ctx.scope, ctx.box.id, ctx.conversation, ctx.request)

    assert {:error, :unknown_request} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :updated,
               1
             )

    assert {:ok, fresh} = reserve(ctx)
    assert DateTime.compare(fresh.inserted_at, original.inserted_at) != :lt
    assert fresh.inserted_at != past
  end

  test "a live request owner excludes duplicate effects and actual owner death permits recovery",
       ctx do
    parent = self()

    child =
      Task.async(fn ->
        receive do
          :start ->
            send(parent, {:reserved, reserve(ctx)})
            receive do: (:finish -> :ok)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(TestRepo, self(), child.pid)
    send(child.pid, :start)
    assert_receive {:reserved, {:ok, original}}, 2_000
    assert {:error, :request_in_flight} = reserve(ctx)

    assert {:error, :request_in_flight} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :updated,
               1
             )

    send(child.pid, :finish)
    assert :ok = Task.await(child)
    assert {:ok, recovered} = reserve(ctx)
    assert recovered.owner_token != original.owner_token

    assert {:ok, _} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :updated,
               1
             )

    effect_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ledger.record_result(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               ctx.ref.token,
               "unresolved",
               effect_id
             )

    assert {:ok, %{completed: true}} =
             Ledger.complete(ctx.scope, ctx.box.id, ctx.conversation, ctx.request)

    assert {:error, :request_complete} =
             Ledger.record_preference(
               ctx.scope,
               ctx.box.id,
               ctx.conversation,
               ctx.request,
               :failed,
               nil
             )
  end
end
