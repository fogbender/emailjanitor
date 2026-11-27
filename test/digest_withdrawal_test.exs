defmodule EmailJanitor.DigestWithdrawalTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Content,
    Digest,
    DigestStagePolicy,
    Policy,
    Reviewer,
    Store,
    TestClassifier,
    TestRepo
  }

  alias EmailJanitor.Digest.{Activity, Event}
  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = Scope.new(TestRepo, "ej_digest_stage")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    now = DateTime.utc_now()
    :ok = Digest.configure(scope, box.id, "Etc/UTC", now)

    headers = %{
      "a1" => %{sender: "sender@example.com", subject: "First restored subject"},
      "a2" => %{sender: "sender@example.com", subject: "Second retained subject"}
    }

    messages = for id <- ["a1", "a2"], do: message(id: id)
    {:ok, proposal} = Reviewer.review(messages, box, MapSet.new(), {TestClassifier, []}, "", 1)
    policy = %Policy{adapter: DigestStagePolicy, context: %{scope: scope, headers: headers}}
    {:ok, {:created, action}} = Store.intent(scope, box.id, proposal, "100", policy: policy)
    # Synthetic durable provider outcome. No real Gmail calls occur in this suite.
    :ok = Store.transition(scope, box.id, action.id, :intent, :done)
    %{scope: scope, inbox: box, action: action, due: DateTime.add(now, 86_400)}
  end

  defp proof(ctx, ids) do
    TestRepo.update_all(
      from(a in Action, where: a.id == ^ctx.action.id),
      [set: [restored_message_ids: ids]],
      prefix: ctx.scope.prefix
    )

    # Positive exact proof does not blanket-change the source action's state.
    assert Store.get(ctx.scope, ctx.inbox.id, ctx.action.id).state == :done
  end

  defp text(ctx, snapshot) do
    {:ok, message} = Digest.render(ctx.scope, snapshot.id)
    Content.read(message.text)
  end

  test "late staged settlement preserves history and retires only positively restored source IDs",
       ctx do
    proof(ctx, ["a1"])
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)
    rows = TestRepo.all(from(a in Activity, order_by: a.message_id), prefix: ctx.scope.prefix)

    assert [
             %Activity{message_id: "a1", retired: true},
             %Activity{message_id: "a2", retired: false}
           ] = rows

    assert {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, ctx.due)
    refute text(ctx, snapshot) =~ "First restored subject"
    assert text(ctx, snapshot) =~ "Second retained subject"
    assert TestRepo.aggregate(Activity, :count, prefix: ctx.scope.prefix) == 2
    assert Store.get(ctx.scope, ctx.inbox.id, ctx.action.id).applied_message_ids == ["a1", "a2"]
  end

  test "claim excludes positive proof even when callback retirement fails or has not run", ctx do
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)
    proof(ctx, ["a1"])

    assert {:error, :fixture} =
             TestRepo.transaction(fn ->
               assert :ok = Digest.withdraw_pending(ctx.scope, ctx.inbox.id, ["a1"])
               TestRepo.rollback(:fixture)
             end)

    refute TestRepo.get_by!(Activity, [message_id: "a1"], prefix: ctx.scope.prefix).retired
    assert {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, ctx.due)
    refute text(ctx, snapshot) =~ "First restored subject"
    assert text(ctx, snapshot) =~ "Second retained subject"
    assert :ok = Digest.withdraw_pending(ctx.scope, ctx.inbox.id, ["a1"])
    assert TestRepo.get_by!(Activity, [message_id: "a1"], prefix: ctx.scope.prefix).retired
  end

  test "already frozen snapshots remain immutable", ctx do
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)
    assert {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, ctx.due)
    frozen = text(ctx, snapshot)
    assert frozen =~ "First restored subject"
    proof(ctx, ["a1"])
    assert :ok = Digest.withdraw_pending(ctx.scope, ctx.inbox.id, ["a1"])
    assert text(ctx, snapshot) == frozen
    refute TestRepo.get_by!(Activity, [message_id: "a1"], prefix: ctx.scope.prefix).retired
  end

  test "old callback retries do not withdraw a newer genuine Done on the same message", ctx do
    proof(ctx, ["a1"])
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)
    old = Store.get(ctx.scope, ctx.inbox.id, ctx.action.id)

    values =
      old
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        restored_message_ids: [],
        fingerprint: "new-genuine-done"
      })

    newer = TestRepo.insert!(struct!(Action, values), prefix: ctx.scope.prefix)

    {:ok, event} =
      Event.new(
        newer.id,
        "a1",
        :done,
        "sender@example.com",
        "New genuine Done",
        DateTime.utc_now()
      )

    {:ok, _} = Digest.record(ctx.scope, ctx.inbox.id, event)
    assert :ok = Digest.withdraw_pending(ctx.scope, ctx.inbox.id, ["a1"])
    refute TestRepo.get_by!(Activity, [source_id: newer.id], prefix: ctx.scope.prefix).retired
    assert {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, ctx.due)
    assert text(ctx, snapshot) =~ "New genuine Done"
    refute text(ctx, snapshot) =~ "First restored subject"
  end

  test "requests without positive source proof cannot hide pending Done and IDs stay bounded",
       ctx do
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)
    assert :ok = Digest.withdraw_pending(ctx.scope, ctx.inbox.id, ["a1"])
    refute TestRepo.get_by!(Activity, [message_id: "a1"], prefix: ctx.scope.prefix).retired
    assert :ok = Digest.withdraw_pending(ctx.scope, ctx.inbox.id, [])

    assert {:error, :invalid_digest_withdrawal} =
             Digest.withdraw_pending(ctx.scope, ctx.inbox.id, ["bad/id"])

    assert {:error, :invalid_digest_withdrawal} =
             Digest.withdraw_pending(ctx.scope, ctx.inbox.id, List.duplicate("a1", 1001))

    assert {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, ctx.due)
    assert text(ctx, snapshot) =~ "First restored subject"
  end
end
