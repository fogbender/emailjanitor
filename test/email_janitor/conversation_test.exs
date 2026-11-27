defmodule EmailJanitor.ConversationFixturePlanner do
  def plan(_inbox, _snapshot, _request, refs, messages, opts),
    do: opts[:script].(refs, messages, opts)
end

defmodule EmailJanitor.ConversationFixtureGmail do
  @behaviour EmailJanitor.Gmail
  def search(_inbox, _query, opts) do
    Agent.get(opts[:state], fn state ->
      {:ok,
       %{
         messages: Enum.map(state.messages, &%{message_id: &1.id, thread_id: &1.thread_id}),
         truncated: false
       }}
    end)
  end

  def thread(inbox, thread, opts) do
    cond do
      opts[:thread_error] -> {:error, opts[:thread_error]}
      opts[:thread_failure] && opts[:thread_failure].() -> {:error, :gmail_unavailable}
      true -> EmailJanitor.TestGmail.thread(inbox, thread, opts)
    end
  end

  def contacted(inbox, keys, opts) do
    result = EmailJanitor.TestGmail.contacted(inbox, keys, opts)
    if hook = opts[:contacted_hook], do: hook.()
    result
  end

  defdelegate history_id(inbox, opts), to: EmailJanitor.TestGmail

  def remove_inbox(inbox, ids, opts) do
    result = EmailJanitor.TestGmail.remove_inbox(inbox, ids, opts)
    if opts[:kill_after_apply], do: Process.exit(self(), :kill)
    result
  end
end

defmodule EmailJanitor.ConversationFixtureBlockedPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(scope, _, _, _, _) do
    if not scope.repo.in_transaction?(), do: raise("admission must be transactional")
    {:blocked, :upgrade_required}
  end

  def reserve(scope, inbox, id, ids, now, _), do: reserve(scope, inbox, id, ids, now)
  def settle(_, _, _, _), do: :ok
  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.ConversationFixtureRestore do
  def apply(_, _, effect_id, _, _, _, opts), do: opts[:fixture_restore].(effect_id)
end

defmodule EmailJanitor.ConversationFixtureFailedSettlement do
  @behaviour EmailJanitor.Policy
  def reserve(_, _, _, _, _), do: :ok
  def reserve(_, _, _, _, _, _), do: :ok
  def settle(_, _, _, _), do: {:error, :temporary_failure}
  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.ConversationTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  import Ecto.Query
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Conversation, Policy, Preferences, Store, TestRepo}
  alias EmailJanitor.Conversation.{Context, Ledger, Plan, Receipt, Reference}
  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)

    {:ok, state} =
      Agent.start_link(fn ->
        %{messages: [message(body: "PRIVATE_EMAIL_SENTINEL")], calls: [], contacted: []}
      end)

    ctx = %Context{
      scope: scope,
      inbox: box,
      conversation_id: Ecto.UUID.generate(),
      gmail: {EmailJanitor.ConversationFixtureGmail, [state: state]},
      planner: EmailJanitor.ConversationFixturePlanner,
      model: [],
      guard: fn -> :ok end,
      policy: Policy.unlimited()
    }

    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    %{ctx: ctx, state: state}
  end

  defp context(ctx, options \\ []) do
    script = fn refs, _messages, opts ->
      plan =
        if refs == [] do
          %Plan{
            operation: :search,
            references: [],
            preference_target: :none,
            query: Content.new("from:sales@vendor.com"),
            instruction: Content.new(""),
            reply: Content.new("")
          }
        else
          %Plan{
            operation: Keyword.get(options, :operation, :done),
            references: Enum.map(refs, & &1.token),
            preference_target: Keyword.get(options, :target, :inbox),
            instruction:
              Content.new(
                Keyword.get(options, :instruction, "Mark unsolicited developer offers Done.")
              ),
            query: Content.new(""),
            reply: Content.new("MODEL_FALSE_COMPLETION_SENTINEL"),
            search_complete: not opts[:search_truncated]
          }
        end

      {:ok, plan}
    end

    %{ctx | model: [script: script]}
  end

  test "a scoped correction immediately teaches and marks exact reviewed IDs Done without persisting the conversation",
       t do
    ctx = context(t.ctx)
    id = Ecto.UUID.generate()

    log =
      capture_log(fn ->
        assert {:ok, reply} =
                 Conversation.respond(ctx, id, Content.new("PRIVATE_REQUEST_SENTINEL"))

        text = Content.read(reply)
        assert text =~ "updated the instructions for this inbox"
        assert text =~ "marked 1 email Done"
        refute text =~ "MODEL_FALSE_COMPLETION_SENTINEL"
      end)

    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    [msg] = Agent.get(t.state, & &1.messages)
    refute "INBOX" in msg.labels
    assert "UNREAD" in msg.labels
    assert "IMPORTANT" in msg.labels
    {:ok, preferences} = Preferences.snapshot(ctx.scope, ctx.inbox.id)
    assert Content.read(preferences.local) == "Mark unsolicited developer offers Done."
    assert preferences.instruction_version == 2

    assert {:ok, replay} =
             Conversation.respond(
               ctx,
               id,
               Content.new("a changed retry must not run another action")
             )

    assert Content.read(replay) =~ "marked 1 email Done"
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    assert TestRepo.aggregate(Action, :count, :id, prefix: ctx.scope.prefix) == 1
    receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, id)

    serialized =
      TestRepo.one(
        from(r in Receipt,
          where: r.id == ^id,
          select: map(r, [:references, :context_references, :results])
        ),
        prefix: ctx.scope.prefix
      )
      |> Jason.encode!()

    assert receipt.completed

    for secret <-
          ~w(PRIVATE_EMAIL_SENTINEL PRIVATE_REQUEST_SENTINEL MODEL_FALSE_COMPLETION_SENTINEL) do
      refute serialized =~ secret
      refute log =~ secret
    end
  end

  test "the free-plan admission still applies to an explicit chat cleanup", t do
    ctx = %{
      context(t.ctx, target: :none, instruction: "")
      | policy: %Policy{
          adapter: EmailJanitor.ConversationFixtureBlockedPolicy,
          context: t.ctx.scope
        }
    }

    assert {:ok, reply} =
             Conversation.respond(
               ctx,
               Ecto.UUID.generate(),
               Content.new("Mark the sales offer Done")
             )

    assert Content.read(reply) =~ "$3/month"
    assert Agent.get(t.state, & &1.calls) == []
    assert Enum.all?(Agent.get(t.state, & &1.messages), &("INBOX" in &1.labels))
  end

  test "sent mail protection and an inactive connection cannot be overridden by conversation",
       t do
    Agent.update(t.state, fn state ->
      %{state | messages: Enum.map(state.messages, &%{&1 | labels: ["SENT", "INBOX", "UNREAD"]})}
    end)

    ctx = context(t.ctx, target: :none, instruction: "")

    assert {:ok, reply} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Mark it Done"))

    assert Content.read(reply) =~ "safeguard"
    assert Agent.get(t.state, & &1.calls) == []
    closed = %{ctx | guard: fn -> {:error, :disconnected} end}

    assert {:error, :conversation_unavailable} =
             Conversation.respond(closed, Ecto.UUID.generate(), Content.new("try again"))

    assert Agent.get(t.state, & &1.calls) == []
  end

  test "ambiguous Gmail completion is reported honestly and replay does not send it again", t do
    ctx = context(t.ctx, target: :none, instruction: "")
    {adapter, opts} = ctx.gmail
    ctx = %{ctx | gmail: {adapter, Keyword.put(opts, :mode, :timeout_after_apply)}}
    id = Ecto.UUID.generate()
    assert {:ok, reply} = Conversation.respond(ctx, id, Content.new("Mark that offer Done"))
    assert Content.read(reply) =~ "uncertain"
    refute Content.read(reply) =~ "marked 1 email Done"
    assert {:ok, _} = Conversation.respond(ctx, id, Content.new("retry"))
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "manual-origin admission is transactional and the trusted reference policy cannot be bypassed",
       t do
    ctx = context(t.ctx, target: :none, instruction: "")
    observer = self()

    policy = fn refs ->
      assert Enum.map(refs, & &1.message_id) == ["message-1"]
      assert Enum.all?(refs, &(not Map.has_key?(&1, :body)))
      %Policy{adapter: EmailJanitor.ConversationFixtureBlockedPolicy, context: ctx.scope}
    end

    admitted = fn id, operation, refs ->
      assert TestRepo.in_transaction?()
      send(observer, {:manual_origin, id, operation, Enum.map(refs, & &1.message_id)})
      :ok
    end

    id = Ecto.UUID.generate()
    ctx = %{ctx | execution_options: [on_plan_admitted: admitted, policy_for_references: policy]}
    assert {:ok, reply} = Conversation.respond(ctx, id, Content.new("Mark that offer Done"))
    assert_receive {:manual_origin, ^id, :done, ["message-1"]}
    assert Content.read(reply) =~ "$3/month"
    assert Agent.get(t.state, & &1.calls) == []

    failed = fn _, _, _ ->
      TestRepo.update_all(EmailJanitor.Store.Mailbox, [set: [instruction_version: 99]],
        prefix: ctx.scope.prefix
      )

      {:error, :manual_origin_unavailable}
    end

    ctx = %{ctx | execution_options: [on_plan_admitted: failed]}
    assert {:error, _} = Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Try again"))
    assert {:ok, 1} = Store.instruction_version(ctx.scope, ctx.inbox.id)
    assert Agent.get(t.state, & &1.calls) == []
  end

  test "follow-up planning receives prior effect facts without retaining the user conversation",
       t do
    ctx = context(t.ctx)

    assert {:ok, _} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("PRIVATE_FIRST_TURN"))

    script = fn _refs, _messages, opts ->
      previous = opts[:previous_effects]
      assert previous["operation"] == "done"
      assert previous["preference_status"] == "updated"
      assert Enum.map(previous["results"], & &1["status"]) == ["done"]
      refute Jason.encode!(previous) =~ "PRIVATE_FIRST_TURN"

      {:ok,
       %Plan{
         operation: :answer,
         references: [],
         preference_target: :none,
         instruction: Content.new(""),
         query: Content.new(""),
         reply: Content.new("The earlier action was confirmed."),
         search_complete: true
       }}
    end

    ctx = %{ctx | model: [script: script]}

    assert {:ok, reply} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("What happened?"))

    assert Content.read(reply) == "The earlier action was confirmed."
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "a missing restore adapter finishes with an honest unsupported result",
       t do
    ctx = context(t.ctx, target: :none)

    assert {:ok, _} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Mark it Done."))

    ctx = context(ctx, operation: :restore, target: :none)
    ctx = %{ctx | execution_options: [restore_adapter: EmailJanitor.MissingRestoreAdapter]}

    request_id = Ecto.UUID.generate()

    assert {:ok, reply} =
             Conversation.respond(ctx, request_id, Content.new("Undo that."))

    assert Content.read(reply) =~ "could not restore"
    refute Content.read(reply) =~ "uncertain"
    refute Content.read(reply) =~ "try again"

    receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
    assert receipt.completed
    assert Enum.map(receipt.results, & &1["status"]) == ["unsupported"]
    assert {:ok, ^reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  for {mode, expected} <- [{nil, "marked 1 email Done"}, {:timeout_after_apply, "uncertain"}] do
    test "confirmed Gmail outcomes survive failed host settlement: #{inspect(mode)}", t do
      mode = unquote(mode)
      ctx = context(t.ctx, target: :none)
      {gmail, opts} = ctx.gmail

      ctx = %{
        ctx
        | gmail: {gmail, Keyword.put(opts, :mode, mode)},
          policy: %Policy{adapter: EmailJanitor.ConversationFixtureFailedSettlement, context: nil}
      }

      request_id = Ecto.UUID.generate()
      assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Mark it Done."))
      assert Content.read(reply) =~ unquote(expected)
      refute Content.read(reply) =~ "Please try again"
      receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
      assert receipt.completed
      assert hd(receipt.results)["effect_id"]
      assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    end
  end

  test "a dead isolated owner resumes pinned effects without asking the model again", t do
    caller = self()
    ctx = context(t.ctx, target: :none)

    ctx = %{
      ctx
      | execution_options: [
          policy_for_references: fn _ ->
            send(caller, {:isolated_owner, self()})
            Process.exit(self(), :kill)
          end
        ]
    }

    request_id = Ecto.UUID.generate()

    assert {:error, :conversation_unavailable} =
             Conversation.respond(ctx, request_id, Content.new("Mark it Done."))

    assert_receive {:isolated_owner, owner}
    refute owner == caller
    refute Process.alive?(owner)
    assert Process.alive?(caller)
    pending = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
    refute pending.completed
    assert EmailJanitor.Owner.proof(pending) == :dead
    assert Agent.get(t.state, & &1.calls) == []

    ctx = %{
      ctx
      | execution_options: [],
        model: [
          script: fn _, _, _ ->
            raise "a resumed effect must not depend on another model plan"
          end
        ]
    }

    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "marked 1 email Done"
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id).completed
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "disconnect during review is checked again before executor admission", t do
    {:ok, connected} = Agent.start_link(fn -> true end)
    ctx = context(t.ctx, target: :none)
    {gmail, opts} = ctx.gmail

    ctx = %{
      ctx
      | guard: fn -> if Agent.get(connected, & &1), do: :ok, else: {:error, :disconnected} end,
        gmail:
          {gmail,
           Keyword.put(opts, :contacted_hook, fn -> Agent.update(connected, fn _ -> false end) end)}
    }

    assert {:error, :effects_pending} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Mark it Done."))

    assert Agent.get(t.state, & &1.calls) == []
    assert TestRepo.aggregate(Action, :count, :id, prefix: ctx.scope.prefix) == 0
    Agent.stop(connected)
  end

  test "resume reports a confirmed nested action even when its workflow died before the receipt result",
       t do
    {:ok, control} = Agent.start_link(fn -> %{} end)
    ctx = context(t.ctx, target: :none)
    {gmail, opts} = ctx.gmail

    ctx = %{
      ctx
      | execution_options: [
          on_plan_admitted: fn _, _, _ ->
            owner = self()
            Agent.update(control, &Map.put(&1, :owner, owner))
            :ok
          end
        ],
        gmail:
          {gmail,
           Keyword.put(opts, :before, fn ->
             Process.exit(Agent.get(control, & &1.owner), :kill)
           end)}
    }

    request_id = Ecto.UUID.generate()

    assert {:error, :conversation_unavailable} =
             Conversation.respond(ctx, request_id, Content.new("Mark it Done."))

    assert_confirmed_action(ctx, 200)
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    Agent.update(t.state, &%{&1 | messages: []})

    ctx = %{
      ctx
      | execution_options: [],
        gmail: {gmail, opts},
        model: [script: fn _, _, _ -> raise "must resume without a model" end]
    }

    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "marked 1 email Done"
    refute Content.read(reply) =~ "needed no inbox change"
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    Agent.stop(control)
  end

  test "completed references need not be loaded again to resume the remaining effects", t do
    ctx = context(t.ctx, target: :none)
    assert {:ok, _} = Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Done."))
    [action] = TestRepo.all(Action, prefix: ctx.scope.prefix)

    {:ok, first} =
      EmailJanitor.Conversation.Reference.new(ctx.inbox.id, "message-1", "thread-1", "", "")

    {:ok, second} =
      EmailJanitor.Conversation.Reference.new(ctx.inbox.id, "message-2", "thread-1", "", "")

    request_id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        plan = %Plan{
          operation: :done,
          references: [first.token, second.token],
          preference_target: :none,
          instruction: Content.new(""),
          reply: Content.new(""),
          query: Content.new(""),
          search_complete: true
        }

        assert {:ok, _} =
                 Ledger.reserve(
                   ctx.scope,
                   ctx.inbox.id,
                   ctx.conversation_id,
                   request_id,
                   plan,
                   [first, second],
                   fn -> :ok end
                 )

        assert {:ok, _} =
                 Ledger.record_result(
                   ctx.scope,
                   ctx.inbox.id,
                   ctx.conversation_id,
                   request_id,
                   first.token,
                   "done",
                   action.id
                 )
      end)

    Task.await(task)
    # The finalized reference has disappeared; only the new message is readable.
    Agent.update(t.state, &%{&1 | messages: [message(id: "message-2")]})
    ctx = %{ctx | model: [script: fn _, _, _ -> raise "must resume without a model" end]}
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "marked 2 emails Done"
    assert Agent.get(t.state, & &1.calls) == [["message-1"], ["message-2"]]
  end

  defp assert_confirmed_action(_ctx, 0), do: flunk("nested action did not finish")

  defp assert_confirmed_action(ctx, attempts) do
    case TestRepo.all(Action, prefix: ctx.scope.prefix) do
      [%{state: :done}] ->
        :ok

      _ ->
        Process.sleep(5)
        assert_confirmed_action(ctx, attempts - 1)
    end
  end

  test "a dispatched intent with a dead owner remains uncertain even without a readable Gmail copy",
       t do
    {:ok, control} = Agent.start_link(fn -> %{} end)
    ctx = context(t.ctx, target: :none)
    {gmail, opts} = ctx.gmail

    ctx = %{
      ctx
      | execution_options: [
          on_plan_admitted: fn _, _, _ ->
            owner = self()
            Agent.update(control, &Map.put(&1, :owner, owner))
            :ok
          end
        ],
        gmail:
          {gmail,
           opts ++
             [
               kill_after_apply: true,
               before: fn ->
                 Process.exit(Agent.get(control, & &1.owner), :kill)
               end
             ]}
    }

    request_id = Ecto.UUID.generate()

    assert {:error, :conversation_unavailable} =
             Conversation.respond(ctx, request_id, Content.new("Done."))

    assert_dispatched_intent(ctx, t.state, 200)
    Agent.update(t.state, &%{&1 | messages: []})

    ctx = %{
      ctx
      | execution_options: [],
        gmail: {gmail, opts},
        model: [script: fn _, _, _ -> raise "no replanning" end]
    }

    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "uncertain"
    refute Content.read(reply) =~ "needed no inbox change"
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    Agent.stop(control)
  end

  test "another conversation's completed action is never claimed by a pending request", t do
    ctx = context(t.ctx, target: :none)
    request_id = reserve_pending(ctx)
    other = %{ctx | conversation_id: Ecto.UUID.generate()}
    assert {:ok, _} = Conversation.respond(other, Ecto.UUID.generate(), Content.new("Done."))
    ctx = %{ctx | model: [script: fn _, _, _ -> raise "no replanning" end]}
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "needed no inbox change"
    refute Content.read(reply) =~ "I marked"
    receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
    assert hd(receipt.results)["effect_id"] == nil
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "temporary lookup failure leaves a pending request retryable", t do
    ctx = context(t.ctx, target: :none)
    request_id = reserve_pending(ctx)
    {gmail, opts} = ctx.gmail
    failing = %{ctx | gmail: {gmail, Keyword.put(opts, :thread_failure, fn -> true end)}}

    assert {:error, :conversation_unavailable} =
             Conversation.respond(failing, request_id, Content.new("Retry."))

    refute Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id).completed
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "marked 1 email Done"
  end

  test "a definitively missing unapplied reference completes without blocking other requests",
       t do
    ctx = context(t.ctx, target: :none)
    request_id = reserve_pending(ctx)
    Agent.update(t.state, &%{&1 | messages: []})
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "could no longer be found"
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id).completed
    assert Agent.get(t.state, & &1.calls) == []
  end

  defp reserve_pending(ctx) do
    request_id = Ecto.UUID.generate()

    {:ok, ref} =
      EmailJanitor.Conversation.Reference.new(ctx.inbox.id, "message-1", "thread-1", "", "")

    task =
      Task.async(fn ->
        plan = %Plan{
          operation: :done,
          references: [ref.token],
          preference_target: :none,
          instruction: Content.new(""),
          query: Content.new(""),
          reply: Content.new(""),
          search_complete: true
        }

        assert {:ok, _} =
                 Ledger.reserve(
                   ctx.scope,
                   ctx.inbox.id,
                   ctx.conversation_id,
                   request_id,
                   plan,
                   [ref],
                   fn -> :ok end
                 )
      end)

    Task.await(task)
    request_id
  end

  defp assert_dispatched_intent(_ctx, _state, 0), do: flunk("nested dispatch did not finish")

  defp assert_dispatched_intent(ctx, state, attempts) do
    case {TestRepo.all(Action, prefix: ctx.scope.prefix), Agent.get(state, & &1.calls)} do
      {[%{state: :intent, dispatch_started_at: at, owner_beam_pid: owner}], [["message-1"]]}
      when not is_nil(at) ->
        pid = :erlang.binary_to_term(owner, [:safe])

        if Process.alive?(pid),
          do:
            (
              Process.sleep(5)
              assert_dispatched_intent(ctx, state, attempts - 1)
            ),
          else: :ok

      _ ->
        Process.sleep(5)
        assert_dispatched_intent(ctx, state, attempts - 1)
    end
  end

  test "an exact missing thread is terminal while a missing profile stays retryable", t do
    ctx = context(t.ctx, target: :none)
    request_id = reserve_pending(ctx)
    {gmail, opts} = ctx.gmail
    profile_error = %{ctx | gmail: {gmail, Keyword.put(opts, :thread_error, :not_found)}}

    assert {:error, :conversation_unavailable} =
             Conversation.respond(profile_error, request_id, Content.new("Retry."))

    refute Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id).completed
    deleted = %{ctx | gmail: {gmail, Keyword.put(opts, :thread_error, :thread_not_found)}}
    assert {:ok, reply} = Conversation.respond(deleted, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "could no longer be found"
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id).completed
  end

  test "a dead prepared action is recovered without Gmail and a fresh bound action finishes the request",
       t do
    ctx = context(t.ctx, target: :none)
    request_id = Ecto.UUID.generate()

    {:ok, ref} =
      EmailJanitor.Conversation.Reference.new(ctx.inbox.id, "message-1", "thread-1", "", "")

    task =
      Task.async(fn ->
        plan = %Plan{
          operation: :done,
          references: [ref.token],
          preference_target: :none,
          instruction: Content.new(""),
          query: Content.new(""),
          reply: Content.new(""),
          search_complete: true
        }

        {:ok, receipt} =
          Ledger.reserve(
            ctx.scope,
            ctx.inbox.id,
            ctx.conversation_id,
            request_id,
            plan,
            [ref],
            fn -> :ok end
          )

        {:ok, proposal} =
          EmailJanitor.Executor.review(
            ctx.scope,
            ctx.inbox,
            "thread-1",
            ctx.gmail,
            {EmailJanitor.TestClassifier, []},
            "",
            1
          )

        policy =
          EmailJanitor.Conversation.ExecutionPolicy.new(
            Policy.unlimited(),
            ctx.scope,
            ctx.inbox.id,
            receipt
          )

        assert {:ok, {:created, action}} =
                 Store.intent(ctx.scope, ctx.inbox.id, proposal, "100", policy: policy)

        action.id
      end)

    old_id = Task.await(task)
    assert Store.get(ctx.scope, ctx.inbox.id, old_id).dispatch_started_at == nil
    assert Agent.get(t.state, & &1.calls) == []
    ctx = %{ctx | model: [script: fn _, _, _ -> raise "no replanning" end]}
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "marked 1 email Done"
    assert Store.get(ctx.scope, ctx.inbox.id, old_id).state == :cancelled
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]

    assert {:done, new_id} =
             Ledger.action_result(ctx.scope, ctx.inbox.id, request_id, "message-1")

    refute new_id == old_id
  end

  test "a request's own historical Done remains attributable after that action was restored", t do
    {:ok, control} = Agent.start_link(fn -> %{} end)
    ctx = context(t.ctx, target: :none)
    {gmail, opts} = ctx.gmail

    ctx = %{
      ctx
      | execution_options: [
          on_plan_admitted: fn _, _, _ ->
            owner = self()
            Agent.update(control, &Map.put(&1, :owner, owner))
            :ok
          end
        ],
        gmail:
          {gmail,
           Keyword.put(opts, :before, fn ->
             Process.exit(Agent.get(control, & &1.owner), :kill)
           end)}
    }

    request_id = Ecto.UUID.generate()

    assert {:error, :conversation_unavailable} =
             Conversation.respond(ctx, request_id, Content.new("Done."))

    assert_confirmed_action(ctx, 200)
    TestRepo.update_all(Action, [set: [state: :restored]], prefix: ctx.scope.prefix)
    Agent.update(t.state, &%{&1 | messages: []})
    ctx = %{ctx | execution_options: [], gmail: {gmail, opts}}
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Content.read(reply) =~ "marked 1 email Done"
    Agent.stop(control)
  end

  test "an existing unresolved action from another request isn't recorded as this request's effect",
       t do
    first = context(t.ctx, target: :none)
    {gmail, opts} = first.gmail
    first = %{first | gmail: {gmail, Keyword.put(opts, :mode, :error_without_apply)}}
    assert {:ok, _} = Conversation.respond(first, Ecto.UUID.generate(), Content.new("Done."))
    ctx = %{context(t.ctx, target: :none) | conversation_id: Ecto.UUID.generate()}
    request_id = Ecto.UUID.generate()

    assert {:ok, reply} =
             Conversation.respond(ctx, request_id, Content.new("Done."))

    receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
    assert receipt.completed
    assert Enum.map(receipt.results, & &1["effect_id"]) == [nil]
    assert Enum.map(receipt.results, & &1["status"]) == ["protected"]
    assert Content.read(reply) =~ "mailbox safeguard"
    refute Content.read(reply) =~ "uncertain"
    assert {:ok, ^reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "a foreign settled action that never applied this message is a terminal safeguard", t do
    ctx = context(t.ctx, target: :none)
    assert {:ok, _} = Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Done."))
    TestRepo.update_all(Action, [set: [applied_message_ids: []]], prefix: ctx.scope.prefix)

    Agent.update(t.state, fn state ->
      %{state | messages: Enum.map(state.messages, &%{&1 | labels: ["INBOX", "UNREAD"]})}
    end)

    ctx = %{ctx | conversation_id: Ecto.UUID.generate()}
    request_id = Ecto.UUID.generate()
    assert {:ok, reply} = Conversation.respond(ctx, request_id, Content.new("Done."))
    assert Content.read(reply) =~ "mailbox safeguard"
    receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
    assert receipt.completed
    assert Enum.map(receipt.results, & &1["effect_id"]) == [nil]
    assert Enum.map(receipt.results, & &1["status"]) == ["protected"]
    assert {:ok, ^reply} = Conversation.respond(ctx, request_id, Content.new("Retry."))
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    assert TestRepo.aggregate(Action, :count, :id, prefix: ctx.scope.prefix) == 1
  end

  test "an email reply pins its original scoped request instead of the latest web action", t do
    original_id = Ecto.UUID.generate()
    ctx = context(t.ctx, target: :none)
    assert {:ok, _} = Conversation.respond(ctx, original_id, Content.new("Done."))

    newer = fn _, _, _ ->
      {:ok,
       %Plan{
         operation: :answer,
         references: [],
         preference_target: :none,
         instruction: Content.new(""),
         query: Content.new(""),
         reply: Content.new("New unrelated answer"),
         search_complete: true
       }}
    end

    assert {:ok, _} =
             Conversation.respond(
               %{ctx | model: [script: newer]},
               Ecto.UUID.generate(),
               Content.new("An unrelated web question.")
             )

    for {previous_id, expected} <- [{original_id, "done"}, {Ecto.UUID.generate(), nil}] do
      script = fn _, _, opts ->
        if expected,
          do: assert(opts[:previous_effects]["operation"] == expected),
          else: assert(is_nil(opts[:previous_effects]))

        assert newer.(nil, nil, nil)
      end

      pinned = %{ctx | previous_request_id: previous_id, model: [script: script]}

      assert {:ok, _} =
               Conversation.respond(
                 pinned,
                 Ecto.UUID.generate(),
                 Content.new("What happened to that?")
               )
    end

    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  for committed <- [true, false] do
    test "interrupted instruction recovery uses pinned IDs and durable change proof: #{committed}",
         t do
      ctx = context(t.ctx)
      {:ok, ref} = Reference.new(ctx.inbox.id, "message-1", "thread-1", "", "")

      {:ok, deleted_context} =
        Reference.new(ctx.inbox.id, "deleted-context", "deleted-thread", "", "")

      id = Ecto.UUID.generate()
      {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.inbox.id)

      plan = %Plan{
        operation: :done,
        references: [ref.token],
        preference_target: :inbox,
        search_complete: true
      }

      assert {:ok, _} =
               EmailJanitor.Owner.workflow(fn ->
                 result =
                   Ledger.reserve(
                     ctx.scope,
                     ctx.inbox.id,
                     ctx.conversation_id,
                     id,
                     plan,
                     [ref, deleted_context],
                     ctx.guard
                   )

                 if unquote(committed) do
                   assert {:ok, _} =
                            Preferences.replace(
                              ctx.scope,
                              {:inbox, ctx.inbox.id},
                              snapshot,
                              Content.new("Keep receipts."),
                              id
                            )
                 end

                 result
               end)

      ctx = %{
        ctx
        | model: [script: fn _, _, _ -> flunk("an admitted request must not replan") end]
      }

      assert {:ok, reply} = Conversation.respond(ctx, id, Content.new("Retry original request."))
      assert Content.read(reply) =~ "marked 1 email Done"

      if unquote(committed),
        do: assert(Content.read(reply) =~ "updated the instructions"),
        else: assert(Content.read(reply) =~ "could not confirm your instruction")

      receipt = Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, id)
      assert receipt.completed
      assert receipt.preference_status == if(unquote(committed), do: :updated, else: :failed)
      assert Agent.get(t.state, & &1.calls) == [["message-1"]]
    end
  end

  test "an interrupted pending correction completes even when its selected email disappeared",
       t do
    ctx = context(t.ctx)
    {:ok, ref} = Reference.new(ctx.inbox.id, "message-1", "thread-1", "", "")
    id = Ecto.UUID.generate()

    plan = %Plan{
      operation: :done,
      references: [ref.token],
      preference_target: :inbox,
      search_complete: true
    }

    assert {:ok, _} =
             EmailJanitor.Owner.workflow(fn ->
               Ledger.reserve(
                 ctx.scope,
                 ctx.inbox.id,
                 ctx.conversation_id,
                 id,
                 plan,
                 [ref],
                 ctx.guard
               )
             end)

    {gmail, opts} = ctx.gmail

    ctx = %{
      ctx
      | gmail: {gmail, Keyword.put(opts, :thread_error, :thread_not_found)},
        model: [script: fn _, _, _ -> flunk("no replan") end]
    }

    assert {:ok, reply} = Conversation.respond(ctx, id, Content.new("Retry."))
    assert Content.read(reply) =~ "could no longer be found"
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, id).completed
    assert Agent.get(t.state, & &1.calls) == []
  end

  test "an already archived selected sibling needs no change while the Inbox sibling is marked Done",
       t do
    Agent.update(
      t.state,
      &%{&1 | messages: [message(), message(id: "message-2", labels: ["UNREAD"])]}
    )

    assert {:ok, reply} =
             Conversation.respond(
               context(t.ctx, target: :none),
               Ecto.UUID.generate(),
               Content.new("Mark both Done.")
             )

    assert Content.read(reply) =~ "marked 1 email Done"
    assert Content.read(reply) =~ "1 email needed no inbox change"
    refute Content.read(reply) =~ "safeguard"
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "a foreign applied action with the email back in Inbox reports a safeguard", t do
    ctx = context(t.ctx, target: :none)
    assert {:ok, _} = Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Done."))
    Agent.update(t.state, &%{&1 | messages: [message()]})
    id = Ecto.UUID.generate()
    assert {:ok, reply} = Conversation.respond(ctx, id, Content.new("Done again."))
    assert Content.read(reply) =~ "safeguard"
    refute Content.read(reply) =~ "needed no inbox change"
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, id).completed
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "restore of mail Janitor never suppressed reports unsupported", t do
    Agent.update(t.state, &%{&1 | messages: [message(labels: ["UNREAD"])]})
    ctx = context(t.ctx, operation: :restore, target: :none)

    assert {:ok, reply} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Put that back."))

    assert Content.read(reply) =~ "could not restore"
    refute Content.read(reply) =~ "needed no inbox change"
    assert Agent.get(t.state, & &1.calls) == []
  end

  test "foreign restore ambiguity is terminal and a live own no-wire intent remains retryable",
       t do
    ctx = context(t.ctx, target: :none)
    assert {:ok, _} = Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Done."))
    ctx = context(ctx, operation: :restore, target: :none)

    fixture = fn result ->
      %{
        ctx
        | execution_options: [
            restore_adapter: EmailJanitor.ConversationFixtureRestore,
            fixture_restore: result
          ]
      }
    end

    foreign_id = Ecto.UUID.generate()

    assert {:ok, reply} =
             Conversation.respond(
               fixture.(fn _ -> {:error, :restore_pending} end),
               foreign_id,
               Content.new("Undo.")
             )

    assert Content.read(reply) =~ "safeguard"
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, foreign_id).completed

    id = Ecto.UUID.generate()

    assert {:error, :effects_pending} =
             Conversation.respond(
               fixture.(fn effect -> {:existing, :intent, effect} end),
               id,
               Content.new("Undo.")
             )

    refute Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, id).completed

    assert {:ok, cancelled} =
             Conversation.respond(
               fixture.(fn effect -> {:existing, :cancelled, effect} end),
               id,
               Content.new("Retry.")
             )

    assert Content.read(cancelled) =~ "could not restore"
    refute Content.read(cancelled) =~ "uncertain"
  end

  test "pre-admission restore version changes can retry the same request", t do
    ctx = context(t.ctx, target: :none)
    assert {:ok, _} = Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Done."))
    ctx = context(ctx, operation: :restore, target: :none)
    id = Ecto.UUID.generate()

    fixture = fn result ->
      %{
        ctx
        | execution_options: [
            restore_adapter: EmailJanitor.ConversationFixtureRestore,
            fixture_restore: result
          ]
      }
    end

    assert {:error, :effects_pending} =
             Conversation.respond(
               fixture.(fn _ -> {:error, :instructions_changed} end),
               id,
               Content.new("Undo.")
             )

    assert {:ok, reply} =
             Conversation.respond(
               fixture.(fn effect -> {:done, effect} end),
               id,
               Content.new("Retry.")
             )

    assert Content.read(reply) =~ "returned 1 email"
  end

  test "a read-only answer cannot claim success for an earlier uncertain Gmail request", t do
    ctx = context(t.ctx, target: :none)
    {gmail, options} = ctx.gmail
    uncertain = %{ctx | gmail: {gmail, Keyword.put(options, :mode, :error_without_apply)}}
    assert {:ok, _} = Conversation.respond(uncertain, Ecto.UUID.generate(), Content.new("Done."))

    script = fn _, _, opts ->
      assert Enum.any?(opts[:previous_effects]["results"], &(&1["status"] == "unresolved"))

      {:ok,
       %Plan{
         operation: :answer,
         references: [],
         preference_target: :none,
         instruction: Content.new(""),
         query: Content.new(""),
         reply: Content.new("FALSE_SUCCESS: Yes, I archived it."),
         search_complete: true
       }}
    end

    assert {:ok, reply} =
             Conversation.respond(
               %{ctx | model: [script: script]},
               Ecto.UUID.generate(),
               Content.new("Did it work?")
             )

    assert Content.read(reply) =~ "uncertain"
    refute Content.read(reply) =~ "FALSE_SUCCESS"
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end

  test "a duplicate that completes while resuming returns a factual saved result", t do
    ctx = t.ctx
    id = Ecto.UUID.generate()

    plan = %Plan{
      operation: :answer,
      references: [],
      preference_target: :none,
      search_complete: true
    }

    assert {:ok, _} =
             EmailJanitor.Owner.workflow(fn ->
               Ledger.reserve(ctx.scope, ctx.inbox.id, ctx.conversation_id, id, plan, [], fn ->
                 :ok
               end)
             end)

    counter = start_supervised!({Agent, fn -> 0 end}, id: :duplicate_guard_counter)

    guard = fn ->
      call = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if call == 2,
        do:
          TestRepo.update_all(from(r in Receipt, where: r.id == ^id), [set: [completed: true]],
            prefix: ctx.scope.prefix
          )

      :ok
    end

    assert {:ok, reply} = Conversation.respond(%{ctx | guard: guard}, id, Content.new("Retry."))
    assert Content.read(reply) == "No email or instruction changes were made."
    assert Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, id).completed
    assert Agent.get(t.state, & &1.calls) == []
  end
end
