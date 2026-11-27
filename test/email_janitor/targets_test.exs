defmodule EmailJanitor.TargetClassifier do
  @behaviour EmailJanitor.Classifier
  def classify(messages, _, opts) do
    if hook = opts[:hook], do: hook.()

    if observer = opts[:observer],
      do: send(observer, {:target_review, Enum.map(messages, &{&1.id, &1.cleanup_target})})

    case opts[:mode] do
      :unreadable ->
        {:keep, :unreadable_content}

      :unavailable ->
        {:error, :synthetic_failure}

      _ ->
        {:ok,
         Keyword.get_lazy(opts, :result, fn ->
           %{
             "decisions" =>
               Enum.map(opts[:target_ids], fn id ->
                 keep? = id in Keyword.get(opts, :keep_ids, [])

                 %{
                   "message_id" => id,
                   "action" => if(keep?, do: "keep", else: "done"),
                   "confidence" => "high",
                   "category" => if(keep?, do: "legitimate", else: "cold_outreach")
                 }
               end)
           }
         end)}
    end
  end
end

defmodule EmailJanitor.TargetPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(ctx, inbox, action, ids, now),
    do: EmailJanitor.TestPolicy.reserve(ctx, inbox, action, ids, now)

  def reserve(ctx, inbox, action, ids, now, admission) do
    if observer = Map.get(ctx, :observer),
      do: send(observer, {:target_admission, ids, admission.inbox_message_ids})

    reserve(ctx, inbox, action, ids, now)
  end

  def settle(ctx, inbox, action, result),
    do: EmailJanitor.TestPolicy.settle(ctx, inbox, action, result)

  def retire_candidate_messages(ctx, inbox, action, ids),
    do: EmailJanitor.TestPolicy.retire_candidate_messages(ctx, inbox, action, ids)

  def retire_candidate(ctx, inbox, action, ids),
    do: EmailJanitor.TestPolicy.retire_candidate(ctx, inbox, action, ids)
end

defmodule EmailJanitor.LegacyRetirementPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(ctx, inbox, action, ids, now),
    do: EmailJanitor.TestPolicy.reserve(ctx, inbox, action, ids, now)

  def reserve(ctx, inbox, action, ids, now, _admission), do: reserve(ctx, inbox, action, ids, now)

  def settle(ctx, inbox, action, result),
    do: EmailJanitor.TestPolicy.settle(ctx, inbox, action, result)

  def retire_candidate(ctx, inbox, action, ids),
    do: EmailJanitor.TestPolicy.retire_candidate(ctx, inbox, action, ids)
end

defmodule EmailJanitor.TargetsTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Executor,
    Message,
    Policy,
    Reviewer,
    Store,
    TargetClassifier,
    TargetDecisions,
    TestGmail,
    TestRepo
  }

  alias EmailJanitor.Store.{Action, Candidate, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "CREATE TABLE ej_test_a.policy_events (action_id text, kind text, message_ids text[], not_applied_ids text[], PRIMARY KEY(action_id,kind))",
      [],
      log: false
    )

    messages = [message(id: "old-context"), message(id: "pitch"), message(id: "keep")]
    state = start_supervised!({Agent, fn -> %{messages: messages, contacted: [], calls: []} end})
    %{scope: scope, inbox: box, state: state, messages: messages}
  end

  defp review(ctx, targets, opts \\ []) do
    Reviewer.review(
      ctx.messages,
      ctx.inbox,
      MapSet.new(),
      {TargetClassifier, opts},
      "",
      1,
      MapSet.new(),
      cleanup_target_ids: targets
    )
  end

  defp execute(ctx, proposal, opts \\ []),
    do: Executor.execute(ctx.scope, ctx.inbox, proposal, {TestGmail, [state: ctx.state]}, opts)

  defp policy(ctx, adapter \\ EmailJanitor.TargetPolicy),
    do: %Policy{adapter: adapter, context: %{scope: ctx.scope, mode: :block, observer: self()}}

  test "every Done target retains its category in a mixed action", ctx do
    decisions =
      for {id, category} <- [{"pitch", "cold_outreach"}, {"keep", "user_instruction"}],
          do: %{
            "message_id" => id,
            "action" => "done",
            "confidence" => "high",
            "category" => category
          }

    assert {:ok, proposal} = review(ctx, ["pitch", "keep"], result: %{"decisions" => decisions})
    assert proposal.category == :mixed

    assert proposal.message_categories == %{
             "pitch" => :cold_outreach,
             "keep" => :user_instruction
           }

    assert {:done, id} = execute(ctx, proposal)

    assert %Action{category: :mixed, message_categories: categories} =
             Store.get(ctx.scope, ctx.inbox.id, id)

    assert categories == %{"pitch" => "cold_outreach", "keep" => "user_instruction"}
    assert [["keep", "pitch"]] = Agent.get(ctx.state, & &1.calls)
  end

  test "disjoint partial keep reviews exhaust and delete a blocked candidate", ctx do
    {:ok, whole} =
      Reviewer.review(
        ctx.messages,
        ctx.inbox,
        MapSet.new(),
        {EmailJanitor.TestClassifier, []},
        "",
        1
      )

    assert {:blocked, :upgrade_required} = execute(ctx, whole, policy: policy(ctx))
    assert [%Candidate{id: original}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    for {id, count} <- [{"pitch", 2}, {"keep", 1}, {"old-context", 0}] do
      assert {:keep, :classifier_kept} =
               Executor.review(
                 ctx.scope,
                 ctx.inbox,
                 "thread-1",
                 {TestGmail, [state: ctx.state]},
                 {TargetClassifier, [keep_ids: [id]]},
                 "",
                 1,
                 cleanup_target_ids: [id],
                 policy: policy(ctx)
               )

      case TestRepo.all(Candidate, prefix: ctx.scope.prefix) do
        [] ->
          assert count == 0

        [%Candidate{id: ^original, remaining_message_ids: remaining}] ->
          assert length(remaining) == count
      end
    end

    assert [] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    {:ok, fresh} = review(ctx, ["pitch", "keep", "old-context"])
    assert {:blocked, :upgrade_required} = execute(ctx, fresh, policy: policy(ctx))

    assert [%Candidate{id: replacement, remaining_message_ids: ["keep", "old-context", "pitch"]}] =
             TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert replacement != original
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "one model review selects Done targets while preserving older INBOX and legitimate context",
       ctx do
    assert {:ok, proposal} = review(ctx, ["pitch", "keep"], keep_ids: ["keep"], observer: self())
    assert proposal.message_ids == ["pitch"]
    assert proposal.evaluated_message_ids == ["keep", "pitch"]
    assert proposal.inbox_message_ids == ["keep", "old-context", "pitch"]
    assert proposal.fingerprint == Message.fingerprint(ctx.messages)
    assert_receive {:target_review, [{"old-context", false}, {"pitch", true}, {"keep", true}]}
    refute_received {:target_review, _}
    assert {:done, _} = execute(ctx, proposal)
    assert [["pitch"]] == Agent.get(ctx.state, & &1.calls)
    current = Agent.get(ctx.state, & &1.messages) |> Map.new(&{&1.id, &1.labels})
    assert "INBOX" in current["old-context"]
    assert "INBOX" in current["keep"]
    assert "UNREAD" in current["pitch"]
    refute "INBOX" in current["pitch"]
  end

  test "full fresh fingerprint and exact INBOX IDs protect all context messages", ctx do
    {:ok, proposal} = review(ctx, ["pitch"])

    for changed <- [
          ctx.messages ++ [message(id: "new-reply")],
          [%{hd(ctx.messages) | labels: ["INBOX"]} | tl(ctx.messages)]
        ] do
      Agent.update(ctx.state, &%{&1 | messages: changed})
      assert {:skip, :proposal_changed} = execute(ctx, proposal)
    end

    Agent.update(ctx.state, &%{&1 | messages: ctx.messages})
    assert {:skip, :proposal_changed} = execute(ctx, %{proposal | inbox_message_ids: ["pitch"]})

    assert {:skip, :proposal_changed} =
             execute(ctx, %{proposal | evaluated_message_ids: ["keep"]})

    assert {:skip, :proposal_changed} =
             execute(ctx, %{proposal | message_ids: ["pitch", "pitch"]})

    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "legacy policies cannot silently authorize a partial-INBOX mutation", ctx do
    blocked = policy(ctx, EmailJanitor.TestPolicy)

    {:ok, whole} =
      Reviewer.review(
        ctx.messages,
        ctx.inbox,
        MapSet.new(),
        {EmailJanitor.TestClassifier, []},
        "",
        1
      )

    assert {:blocked, :upgrade_required} = execute(ctx, whole, policy: blocked)
    assert [original] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    {:ok, proposal} = review(ctx, ["pitch"])

    assert {:error, :partial_admission_unsupported} = execute(ctx, proposal, policy: blocked)

    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [^original] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert %{rows: [["reserve"]]} =
             Ecto.Adapters.SQL.query!(TestRepo, "SELECT kind FROM ej_test_a.policy_events", [],
               log: false
             )

    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "admission receives the full INBOX snapshot separately from selected Done IDs", ctx do
    {:ok, proposal} = review(ctx, ["pitch", "keep"], keep_ids: ["keep"])
    assert {:blocked, :upgrade_required} = execute(ctx, proposal, policy: policy(ctx))
    assert_receive {:target_admission, ["pitch"], ["keep", "old-context", "pitch"]}
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "malformed proposal selections are rejected before a safeguard can retire context", ctx do
    {:ok, whole} =
      Reviewer.review(
        ctx.messages,
        ctx.inbox,
        MapSet.new(),
        {EmailJanitor.TestClassifier, []},
        "",
        1
      )

    assert {:blocked, :upgrade_required} = execute(ctx, whole, policy: policy(ctx))
    assert [original] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
    {:ok, partial} = review(ctx, ["pitch"])
    Agent.update(ctx.state, &%{&1 | contacted: ["vendor.com"]})

    for malformed <- [
          %{partial | evaluated_message_ids: false},
          %{partial | evaluated_message_ids: "pitch"},
          %{partial | evaluated_message_ids: []},
          %{partial | evaluated_message_ids: ["pitch", "pitch"]},
          %{partial | inbox_message_ids: false}
        ] do
      assert {:skip, :proposal_changed} = execute(ctx, malformed, policy: policy(ctx))
    end

    assert [^original] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert %{rows: []} =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT kind FROM ej_test_a.policy_events WHERE kind='retire'",
               [],
               log: false
             )

    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  for new_guard <- [:correspondence, :sent_reply] do
    test "a new execute-time #{new_guard} guard retires targets while preserving INBOX context",
         ctx do
      {:ok, whole} =
        Reviewer.review(
          ctx.messages,
          ctx.inbox,
          MapSet.new(),
          {EmailJanitor.TestClassifier, []},
          "",
          1
        )

      assert {:blocked, :upgrade_required} = execute(ctx, whole, policy: policy(ctx))
      assert [%Candidate{id: id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)
      {:ok, partial} = review(ctx, ["pitch"])

      expected =
        case unquote(new_guard) do
          :correspondence ->
            Agent.update(ctx.state, &%{&1 | contacted: ["vendor.com"]})
            :prior_correspondence

          :sent_reply ->
            Agent.update(
              ctx.state,
              &%{&1 | messages: &1.messages ++ [message(id: "sent-reply", labels: ["SENT"])]}
            )

            :proposal_changed
        end

      assert {:skip, ^expected} = execute(ctx, partial, policy: policy(ctx))
      assert [%Candidate{id: ^id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

      assert %{rows: [[["pitch"]]]} =
               Ecto.Adapters.SQL.query!(
                 TestRepo,
                 "SELECT message_ids FROM ej_test_a.policy_events WHERE action_id=$1 AND kind='retire'",
                 [id],
                 log: false
               )

      assert [] = Agent.get(ctx.state, & &1.calls)
    end
  end

  test "fresh keep retires evaluated IDs but preserves unevaluated INBOX pending context", ctx do
    {:ok, whole} =
      Reviewer.review(
        ctx.messages,
        ctx.inbox,
        MapSet.new(),
        {EmailJanitor.TestClassifier, []},
        "",
        1
      )

    assert {:blocked, :upgrade_required} = execute(ctx, whole, policy: policy(ctx))
    assert [%Candidate{id: id}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert {:keep, :classifier_kept} =
             Executor.review(
               ctx.scope,
               ctx.inbox,
               "thread-1",
               {TestGmail, [state: ctx.state]},
               {TargetClassifier, [keep_ids: ["pitch"]]},
               "",
               1,
               cleanup_target_ids: ["pitch"],
               policy: policy(ctx)
             )

    assert [%Candidate{id: ^id, message_ids: ["keep", "old-context", "pitch"]}] =
             TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert %{rows: [[["pitch"]]]} =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT message_ids FROM ej_test_a.policy_events WHERE action_id=$1 AND kind='retire'",
               [id],
               log: false
             )

    Agent.update(ctx.state, fn state ->
      %{
        state
        | messages:
            Enum.map(state.messages, fn message ->
              if message.id == "old-context", do: %{message | labels: ["UNREAD"]}, else: message
            end)
      }
    end)

    assert {:keep, :classifier_kept} =
             Executor.review(
               ctx.scope,
               ctx.inbox,
               "thread-1",
               {TestGmail, [state: ctx.state]},
               {TargetClassifier, [keep_ids: ["pitch"]]},
               "",
               1,
               cleanup_target_ids: ["pitch"],
               policy: policy(ctx)
             )

    assert %{rows: [[["old-context"]]]} =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT message_ids FROM ej_test_a.policy_events WHERE action_id=$1 AND kind='retire'",
               [id],
               log: false
             )

    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "an unreadable or failed model does not withdraw unreviewed pending work", ctx do
    {:ok, whole} =
      Reviewer.review(
        ctx.messages,
        ctx.inbox,
        MapSet.new(),
        {EmailJanitor.TestClassifier, []},
        "",
        1
      )

    assert {:blocked, :upgrade_required} = execute(ctx, whole, policy: policy(ctx))

    for {mode, expected} <- [
          unreadable: {:keep, :unreadable_content},
          unavailable: {:error, :model_unavailable}
        ] do
      assert ^expected =
               Executor.review(
                 ctx.scope,
                 ctx.inbox,
                 "thread-1",
                 {TestGmail, [state: ctx.state]},
                 {TargetClassifier, [mode: mode]},
                 "",
                 1,
                 cleanup_target_ids: ["pitch"],
                 policy: policy(ctx)
               )
    end

    assert [%Candidate{}] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    assert %{rows: []} =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT message_ids FROM ej_test_a.policy_events WHERE kind='retire'",
               [],
               log: false
             )
  end

  test "target mask does not weaken sent, draft, correspondence or restoration guards", ctx do
    for label <- ["SENT", "DRAFT"] do
      messages = [%{hd(ctx.messages) | labels: [label]} | tl(ctx.messages)]

      assert {:keep, :sent_or_draft} =
               review(%{ctx | messages: messages}, ["pitch"], observer: self())
    end

    for {contacts, restored, reason} <- [
          {MapSet.new(["vendor.com"]), MapSet.new(), :prior_correspondence},
          {MapSet.new(), MapSet.new(["old-context"]), :manually_restored}
        ] do
      assert {:keep, ^reason} =
               Reviewer.review(
                 ctx.messages,
                 ctx.inbox,
                 contacts,
                 {TargetClassifier, [observer: self()]},
                 "",
                 1,
                 restored,
                 cleanup_target_ids: ["pitch"]
               )
    end

    refute_received {:target_review, _}
  end

  test "model decisions must cover exactly the selected target IDs", ctx do
    done = %{"action" => "done", "confidence" => "high", "category" => "cold_outreach"}
    valid = %{"decisions" => [Map.put(done, "message_id", "pitch")]}
    assert {:ok, %{"pitch" => _}} = TargetDecisions.parse(valid, ["pitch"])

    for object <- [
          %{"decisions" => []},
          %{"decisions" => [Map.put(done, "message_id", "old-context")]},
          %{"decisions" => valid["decisions"] ++ valid["decisions"]},
          %{"decisions" => [Map.put(hd(valid["decisions"]), "reason", "PRIVATE_BODY")]},
          %{"decisions" => [Map.put(hd(valid["decisions"]), "category", "legitimate")]},
          Map.put(valid, "extra", "PRIVATE_BODY")
        ] do
      assert {:error, :invalid_decision} = TargetDecisions.parse(object, ["pitch"])
      assert {:error, :invalid_decision} = review(ctx, ["pitch"], result: object)
    end

    assert {:error, :invalid_decision} = TargetDecisions.parse(valid, ["pitch", "keep"])

    assert {:error, :invalid_decision} =
             TargetDecisions.parse("{PRIVATE_BODY_SENTINEL", ["pitch"])

    assert {:error, :invalid_decision} =
             TargetDecisions.parse(String.duplicate("x", 16_385), ["pitch"])
  end

  test "legacy whole-candidate retirement is never invoked for a partial withdrawal", ctx do
    legacy = %Policy{
      adapter: EmailJanitor.LegacyRetirementPolicy,
      context: %{scope: ctx.scope, mode: :block}
    }

    assert {:ok, proposal} = review(ctx, ["pitch", "keep"])

    assert {:blocked, :upgrade_required} =
             Executor.execute(ctx.scope, ctx.inbox, proposal, {TestGmail, [state: ctx.state]},
               policy: legacy
             )

    [candidate] = TestRepo.all(Candidate, prefix: ctx.scope.prefix)

    keep_review = fn policy ->
      Executor.review(
        ctx.scope,
        ctx.inbox,
        "thread-1",
        {TestGmail, [state: ctx.state]},
        {TargetClassifier, [keep_ids: ["pitch"]]},
        "",
        1,
        cleanup_target_ids: ["pitch"],
        policy: policy
      )
    end

    assert {:error, :partial_retirement_unsupported} = keep_review.(legacy)

    assert TestRepo.get!(Candidate, candidate.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["keep", "pitch"]

    events = fn ->
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT kind,message_ids FROM #{ctx.scope.prefix}.policy_events WHERE action_id=$1 ORDER BY kind",
        [candidate.id],
        log: false
      ).rows
    end

    assert [["reserve", ["keep", "pitch"]]] == events.()
    exact = %Policy{adapter: EmailJanitor.TargetPolicy, context: legacy.context}
    assert {:keep, :classifier_kept} = keep_review.(exact)

    assert TestRepo.get!(Candidate, candidate.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["keep"]

    assert [["reserve", ["keep"]], ["retire", ["pitch"]]] == events.()
  end

  test "whole retirement of a cancelled legacy action stays retired on later subset review",
       ctx do
    legacy = %Policy{
      adapter: EmailJanitor.LegacyRetirementPolicy,
      context: %{scope: ctx.scope, mode: :allow}
    }

    assert {:ok, proposal} = review(ctx, ["pitch", "keep"])

    {:ok, {:created, action}} =
      Store.intent(ctx.scope, ctx.inbox.id, proposal, "100", policy: legacy)

    :ok = Store.cancel_prepared(ctx.scope, ctx.inbox.id, action.id, action.owner_token)

    keep_review = fn targets ->
      Executor.review(
        ctx.scope,
        ctx.inbox,
        "thread-1",
        {TestGmail, [state: ctx.state]},
        {TargetClassifier, [keep_ids: targets]},
        "",
        1,
        cleanup_target_ids: targets,
        policy: legacy
      )
    end

    assert {:error, :partial_retirement_unsupported} = keep_review.(["pitch"])
    assert Store.get(ctx.scope, ctx.inbox.id, action.id).remaining_metadata_ids == nil
    assert {:keep, :classifier_kept} = keep_review.(["pitch", "keep"])
    assert Store.get(ctx.scope, ctx.inbox.id, action.id).remaining_metadata_ids == []
    assert {:keep, :classifier_kept} = keep_review.(["pitch"])
    assert Store.get(ctx.scope, ctx.inbox.id, action.id).remaining_metadata_ids == []
  end
end
