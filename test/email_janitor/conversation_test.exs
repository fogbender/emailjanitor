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

  defdelegate thread(inbox, thread, opts), to: EmailJanitor.TestGmail
  defdelegate contacted(inbox, keys, opts), to: EmailJanitor.TestGmail
  defdelegate history_id(inbox, opts), to: EmailJanitor.TestGmail
  defdelegate remove_inbox(inbox, ids, opts), to: EmailJanitor.TestGmail
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

defmodule EmailJanitor.ConversationTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  import Ecto.Query
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Conversation, Policy, Preferences, Store, TestRepo}
  alias EmailJanitor.Conversation.{Context, Ledger, Plan, Receipt}
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

  test "a missing restore adapter reports unavailable without claiming an uncertain Gmail attempt",
       t do
    ctx = context(t.ctx, target: :none)

    assert {:ok, _} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Mark it Done."))

    ctx = context(ctx, operation: :restore, target: :none)
    ctx = %{ctx | execution_options: [restore_adapter: EmailJanitor.MissingRestoreAdapter]}

    assert {:ok, reply} =
             Conversation.respond(ctx, Ecto.UUID.generate(), Content.new("Undo that."))

    assert Content.read(reply) =~ "could not finish processing"
    refute Content.read(reply) =~ "uncertain"
    refute Content.read(reply) =~ "returned"
    assert Agent.get(t.state, & &1.calls) == [["message-1"]]
  end
end
