defmodule EmailJanitor.ReviewContextGmail do
  @behaviour EmailJanitor.Gmail
  def thread(_, _, opts) do
    Agent.get_and_update(opts[:state], fn state ->
      {{:ok, state.messages}, %{state | fetches: state.fetches + 1}}
    end)
  end

  defdelegate contacted(inbox, keys, opts), to: EmailJanitor.TestGmail
  defdelegate history_id(inbox, opts), to: EmailJanitor.TestGmail
  defdelegate remove_inbox(inbox, ids, opts), to: EmailJanitor.TestGmail
end

defmodule EmailJanitor.ReviewContextPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(context, _, _, ids, _) do
    true = context.scope.repo.in_transaction?()
    send(context.observer, {:reserved, context.tag, ids})
    if context[:block], do: {:blocked, :upgrade_required}, else: :ok
  end

  def reserve(context, inbox, action, ids, now, _), do: reserve(context, inbox, action, ids, now)

  def settle(context, _, _, result) do
    send(context.observer, {:settled, context.tag, result})
    :ok
  end

  def retire_candidate(context, _, _, ids) do
    true = context.scope.repo.in_transaction?()
    send(context.observer, {:retired, context.tag, ids})
    :ok
  end

  def retire_candidate_messages(context, inbox, action, ids),
    do: retire_candidate(context, inbox, action, ids)
end

defmodule EmailJanitor.ReviewContextTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Content, Executor, Message, Policy, Store, TestClassifier, TestRepo}
  alias EmailJanitor.Store.Scope

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)

    msg =
      message(
        headers: [{"From", "Sales <sales@vendor.com>"}, {"Subject", "Fresh subject"}],
        body: "PRIVATE_CONTEXT_BODY"
      )

    {:ok, state} =
      Agent.start_link(fn -> %{messages: [msg], calls: [], contacted: [], fetches: 0} end)

    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    %{
      scope: scope,
      box: box,
      state: state,
      gmail: {EmailJanitor.ReviewContextGmail, [state: state]}
    }
  end

  defp policy(t, tag, options \\ []) do
    %Policy{
      adapter: EmailJanitor.ReviewContextPolicy,
      context: %{scope: t.scope, observer: self(), tag: tag, block: options[:block] || false}
    }
  end

  test "fresh headers derive one policy used for admission and settlement without another review fetch",
       t do
    observer = self()
    fresh = policy(t, "Fresh subject")

    factory = fn [message] ->
      refute t.scope.repo.in_transaction?()
      assert Message.header(message, "subject") == "Fresh subject"
      assert Content.read(message.body) == "PRIVATE_CONTEXT_BODY"
      send(observer, :factory_called)
      {:ok, fresh}
    end

    assert {{:ok, proposal}, ^fresh} =
             Executor.review_with_context(
               t.scope,
               t.box,
               "thread-1",
               t.gmail,
               {TestClassifier, []},
               "",
               1,
               policy: policy(t, "BASE"),
               context_factory: factory
             )

    assert_receive :factory_called
    assert Agent.get(t.state, & &1.fetches) == 1
    assert {:done, _} = Executor.execute(t.scope, t.box, proposal, t.gmail, policy: fresh)
    assert_receive {:reserved, "Fresh subject", ["message-1"]}
    assert_receive {:settled, "Fresh subject", {:reconciled, ["message-1"], []}}
    refute_receive {:reserved, "BASE", _}
    refute_receive :factory_called
  end

  test "a fresh Keep retires a prior candidate through the derived policy", t do
    assert {:ok, proposal} =
             Executor.review(t.scope, t.box, "thread-1", t.gmail, {TestClassifier, []}, "", 1)

    assert {:blocked, :upgrade_required} =
             Executor.execute(t.scope, t.box, proposal, t.gmail,
               policy: policy(t, "OLD", block: true)
             )

    assert_receive {:reserved, "OLD", _}
    fresh = policy(t, "Fresh subject")

    classifier =
      {TestClassifier,
       [result: %{"action" => "keep", "confidence" => "high", "category" => "legitimate"}]}

    assert {{:keep, :classifier_kept}, ^fresh} =
             Executor.review_with_context(t.scope, t.box, "thread-1", t.gmail, classifier, "", 1,
               context_factory: fn _ -> {:ok, fresh} end
             )

    assert_receive {:retired, "Fresh subject", ["message-1"]}
    assert TestRepo.all(EmailJanitor.Store.Candidate, prefix: t.scope.prefix) == []
    assert Agent.get(t.state, & &1.calls) == []
  end

  test "factory refusal, invalid values and exceptions never fall back to base admission", t do
    for factory <- [
          fn _ -> {:error, :unavailable} end,
          fn _ -> {:ok, %{}} end,
          fn _ -> raise "PRIVATE_CONTEXT_FACTORY" end,
          fn _ -> throw(:private_context_factory) end,
          nil
        ] do
      assert {{:error, :policy_unavailable}, nil} =
               Executor.review_with_context(
                 t.scope,
                 t.box,
                 "thread-1",
                 t.gmail,
                 {TestClassifier, []},
                 "",
                 1,
                 policy: policy(t, "BASE"),
                 context_factory: factory
               )
    end

    refute_receive {:reserved, _, _}
    assert Agent.get(t.state, & &1.calls) == []
  end

  test "legacy review keeps its return shape and does not invoke the new callback", t do
    assert {:ok, _} =
             Executor.review(t.scope, t.box, "thread-1", t.gmail, {TestClassifier, []}, "", 1,
               context_factory: fn _ -> flunk("legacy review must ignore context factories") end
             )

    assert Agent.get(t.state, & &1.fetches) == 1
  end

  test "an invalid thread never reaches the metadata factory", t do
    Agent.update(t.state, &%{&1 | messages: [message(thread_id: "other-thread")]})

    assert {{:error, :proposal_changed}, nil} =
             Executor.review_with_context(
               t.scope,
               t.box,
               "thread-1",
               t.gmail,
               {TestClassifier, []},
               "",
               1,
               context_factory: fn _ -> flunk("foreign thread") end
             )
  end

  test "bad legacy options remain a fixed error rather than crashing the caller", t do
    assert {:error, :executor_unavailable} =
             Executor.review(
               t.scope,
               t.box,
               "thread-1",
               t.gmail,
               {TestClassifier, []},
               "",
               1,
               :bad
             )
  end

  test "a refusing factory preserves pending candidates without retiring through the base policy",
       t do
    assert {:ok, proposal} =
             Executor.review(t.scope, t.box, "thread-1", t.gmail, {TestClassifier, []}, "", 1)

    assert {:blocked, :upgrade_required} =
             Executor.execute(t.scope, t.box, proposal, t.gmail,
               policy: policy(t, "OLD", block: true)
             )

    assert_receive {:reserved, "OLD", _}
    [candidate] = TestRepo.all(EmailJanitor.Store.Candidate, prefix: t.scope.prefix)

    keep =
      {TestClassifier,
       [result: %{"action" => "keep", "confidence" => "high", "category" => "legitimate"}]}

    assert {{:error, :policy_unavailable}, nil} =
             Executor.review_with_context(t.scope, t.box, "thread-1", t.gmail, keep, "", 1,
               policy: policy(t, "BASE"),
               context_factory: fn _ -> {:error, :unavailable} end
             )

    assert [^candidate] = TestRepo.all(EmailJanitor.Store.Candidate, prefix: t.scope.prefix)
    refute_receive {:retired, "BASE", _}
    assert Agent.get(t.state, & &1.calls) == []
  end
end
