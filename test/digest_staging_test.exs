defmodule EmailJanitor.DigestStagePolicy do
  @behaviour EmailJanitor.Policy
  alias EmailJanitor.{Digest, Store}
  alias EmailJanitor.Digest.Event

  def reserve(context, inbox, action, ids, now) do
    true = context.scope.repo.in_transaction?()
    nil = Store.get(context.scope, inbox, action)

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      header = Map.fetch!(context.headers, id)
      {:ok, event} = Event.new(action, id, :done, header.sender, header.subject, now)

      case Digest.stage(context.scope, inbox, event) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def settle(context, inbox, action, _result) do
    context.scope.repo.query!(
      "INSERT INTO #{context.scope.prefix}.digest_stage_host (action_id) VALUES ($1) ON CONFLICT DO NOTHING",
      [action],
      log: false
    )

    with :ok <- Digest.confirm_staged(context.scope, inbox, action) do
      if Agent.get(context.control, & &1), do: {:error, :retry_fixture}, else: :ok
    end
  end

  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.DigestStagingTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Content,
    Digest,
    DigestStagePolicy,
    Executor,
    Inbox,
    Policy,
    Reviewer,
    Store,
    TestClassifier,
    TestGmail,
    TestRepo
  }

  alias EmailJanitor.Digest.{Activity, Event, Staged}
  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = Scope.new(TestRepo, "ej_digest_stage")
    {:ok, other} = Scope.new(TestRepo, "ej_digest_stage_other")
    box = inbox()
    now = DateTime.utc_now()

    for target <- [scope, other] do
      {:ok, _} = Store.add_inbox(target, box)
      :ok = Digest.configure(target, box.id, "Etc/UTC", now)

      TestRepo.query!(
        "CREATE TABLE #{target.prefix}.digest_stage_host (action_id text PRIMARY KEY)",
        [],
        log: false
      )
    end

    headers = %{
      "a1" => %{sender: "Sales <sales@vendor.com>", subject: "First subject"},
      "a2" => %{sender: "Sales <sales@vendor.com>", subject: "Second subject"}
    }

    messages =
      for id <- ["a1", "a2"],
          do:
            message(
              id: id,
              headers: [{"From", headers[id].sender}, {"Subject", headers[id].subject}],
              body: "PRIVATE_STAGING_BODY_SENTINEL"
            )

    {:ok, proposal} = Reviewer.review(messages, box, MapSet.new(), {TestClassifier, []}, "", 1)
    state = start_supervised!({Agent, fn -> %{messages: messages, contacted: [], calls: []} end})
    control = start_supervised!({Agent, fn -> true end}, id: :staging_control)

    %{
      scope: scope,
      other: other,
      inbox: box,
      proposal: proposal,
      headers: headers,
      state: state,
      control: control,
      report_at: DateTime.add(now, 86_400)
    }
  end

  defp policy(ctx, headers \\ :captured),
    do: %Policy{
      adapter: DigestStagePolicy,
      context: %{
        scope: ctx.scope,
        control: ctx.control,
        headers: if(headers == :captured, do: ctx.headers, else: headers)
      }
    }

  defp execute(ctx),
    do:
      Executor.execute(ctx.scope, ctx.inbox, ctx.proposal, {TestGmail, [state: ctx.state]},
        policy: policy(ctx)
      )

  defp rows(ctx, schema), do: TestRepo.all(schema, prefix: ctx.scope.prefix)

  test "crash-safe metadata survives failed settlement and retry needs no headers or Gmail",
       ctx do
    assert {:settlement_pending, action_id, :done} = execute(ctx)

    assert %Action{applied_message_ids: ["a1", "a2"]} =
             action = Store.get(ctx.scope, ctx.inbox.id, action_id)

    assert length(rows(ctx, Staged)) == 2
    assert rows(ctx, Activity) == []
    assert TestRepo.aggregate("digest_stage_host", :count, prefix: ctx.scope.prefix) == 0
    assert {:ok, :inactive} = Digest.tick(ctx.scope, ctx.inbox.id, ctx.report_at)

    Agent.update(ctx.control, fn _ -> false end)

    assert {:existing, ^action_id, :done} =
             Executor.settle_action(ctx.scope, ctx.inbox, action_id, policy: policy(ctx, %{}))

    assert rows(ctx, Staged) == []
    assert length(rows(ctx, Activity)) == 2
    assert TestRepo.aggregate("digest_stage_host", :count, prefix: ctx.scope.prefix) == 1
    assert Enum.all?(rows(ctx, Activity), &(&1.occurred_at == action.dispatch_started_at))
    assert [["a1", "a2"]] == Agent.get(ctx.state, & &1.calls)

    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action_id)
    assert length(rows(ctx, Activity)) == 2

    assert {:ok, {:ready, snapshot}} =
             Digest.tick(ctx.scope, ctx.inbox.id, DateTime.add(ctx.report_at, 86_400))

    assert {:ok, rendered} = Digest.render(ctx.scope, snapshot.id)
    assert Content.read(rendered.text) =~ "First subject"
    refute Content.read(rendered.text) =~ "PRIVATE_STAGING_BODY_SENTINEL"
  end

  test "intent and unresolved never appear, while proven unapplied cancellation discards stages",
       ctx do
    assert {:ok, {:created, action}} =
             Store.intent(ctx.scope, ctx.inbox.id, ctx.proposal, "100", policy: policy(ctx))

    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action.id)
    assert length(rows(ctx, Staged)) == 2
    assert rows(ctx, Activity) == []
    assert :ok = Store.cancel_prepared(ctx.scope, ctx.inbox.id, action.id, action.owner_token)
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action.id)
    assert rows(ctx, Staged) == []
    assert rows(ctx, Activity) == []
    assert Agent.get(ctx.state, & &1.calls) == []
  end

  test "unknown dispatch outcome retains its stages without publishing", ctx do
    assert {:ok, {:created, action}} =
             Store.intent(ctx.scope, ctx.inbox.id, ctx.proposal, "100", policy: policy(ctx))

    assert :ok = Store.transition(ctx.scope, ctx.inbox.id, action.id, :intent, :unresolved)
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action.id)
    assert length(rows(ctx, Staged)) == 2
    assert rows(ctx, Activity) == []
  end

  test "partial durable proof promotes only exact applied IDs and uses original dispatch time",
       ctx do
    assert {:settlement_pending, action_id, :done} = execute(ctx)
    action = Store.get(ctx.scope, ctx.inbox.id, action_id)

    TestRepo.update_all(
      from(a in Action, where: a.id == ^action_id),
      [
        set: [
          applied_message_ids: ["a1"],
          state: :restored,
          restored_message_ids: ["a1"],
          updated_at: DateTime.add(action.updated_at, 86_400)
        ]
      ],
      prefix: ctx.scope.prefix
    )

    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action_id)
    assert [%Activity{message_id: "a1", occurred_at: occurred}] = rows(ctx, Activity)
    assert occurred == action.dispatch_started_at
    assert rows(ctx, Staged) == []
  end

  test "missing staged headers fail atomically, then a durable repair can retry", ctx do
    assert {:settlement_pending, action_id, :done} = execute(ctx)
    TestRepo.delete_all(from(s in Staged, where: s.message_id == "a2"), prefix: ctx.scope.prefix)

    assert {:error, :missing_digest_stage} =
             Digest.confirm_staged(ctx.scope, ctx.inbox.id, action_id)

    assert rows(ctx, Activity) == []
    assert length(rows(ctx, Staged)) == 1

    {:ok, event} =
      Event.new(action_id, "a2", :done, "sales@vendor.com", "Second subject", DateTime.utc_now())

    assert :ok = Digest.stage(ctx.scope, ctx.inbox.id, event)
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action_id)
    assert length(rows(ctx, Activity)) == 2
    assert :ok = Digest.stage(ctx.scope, ctx.inbox.id, event)
    assert rows(ctx, Staged) == []
  end

  test "scopes and inboxes cannot borrow another action's applied proof", ctx do
    assert {:settlement_pending, action_id, :done} = execute(ctx)
    {:ok, box2} = Inbox.new("other-inbox", "other@acme.com")
    {:ok, _} = Store.add_inbox(ctx.scope, box2)

    {:ok, event} =
      Event.new(action_id, "a1", :done, "sender@example.com", "Other scope", DateTime.utc_now())

    assert :ok = Digest.stage(ctx.other, ctx.inbox.id, event)
    assert :ok = Digest.stage(ctx.scope, box2.id, event)

    assert {:error, :unknown_digest_action} =
             Digest.confirm_staged(ctx.other, ctx.inbox.id, action_id)

    assert {:error, :unknown_digest_action} = Digest.confirm_staged(ctx.scope, box2.id, action_id)
    assert TestRepo.all(Activity, prefix: ctx.other.prefix) == []
    assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, action_id)
    assert Enum.all?(rows(ctx, Activity), &(&1.inbox_id == ctx.inbox.id))
    assert TestRepo.aggregate(Staged, :count, prefix: ctx.other.prefix) == 1
  end

  test "staging revalidates metadata, rejects incompatible replay, and requires no schedule",
       ctx do
    TestRepo.delete_all(Digest.Schedule, prefix: ctx.scope.prefix)
    action = Ecto.UUID.generate()

    {:ok, event} =
      Event.new(
        action,
        "a1",
        :done,
        "First <one@example.com>, Second <two@example.com>",
        String.duplicate("x", 1000),
        DateTime.utc_now()
      )

    assert :ok = Digest.stage(ctx.scope, ctx.inbox.id, event)
    assert :ok = Digest.stage(ctx.scope, ctx.inbox.id, event)
    assert [%Staged{sender: "one@example.com", subject: subject}] = rows(ctx, Staged)
    assert byte_size(subject) == 256

    assert {:error, :digest_stage_conflict} =
             Digest.stage(ctx.scope, ctx.inbox.id, %{event | subject: "Different metadata"})

    assert {:error, :invalid_digest_stage} =
             Digest.stage(ctx.scope, ctx.inbox.id, %{event | kind: :would_have_done})

    assert {:error, :unknown_digest_action} =
             Digest.confirm_staged(ctx.scope, ctx.inbox.id, action)

    assert length(rows(ctx, Staged)) == 1
    assert rows(ctx, Activity) == []
  end
end
