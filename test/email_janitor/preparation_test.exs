defmodule EmailJanitor.PreparedTestGmail do
  @behaviour EmailJanitor.Gmail
  alias EmailJanitor.{TestGmail, TestRepo}
  alias EmailJanitor.Store.Action

  @impl true
  def thread(inbox, thread, opts), do: TestGmail.thread(inbox, thread, opts)
  @impl true
  def contacted(inbox, keys, opts), do: TestGmail.contacted(inbox, keys, opts)
  @impl true
  def history_id(inbox, opts), do: TestGmail.history_id(inbox, opts)
  @impl true
  def remove_inbox(_, _, _), do: {:error, :preparation_was_skipped}

  @impl true
  def prepare_remove_inbox(inbox, ids, opts) do
    send(opts[:observer], {:preparing, self(), TestRepo.in_transaction?()})

    case opts[:prepare] do
      :fail ->
        {:error, :profile_unavailable}

      :block ->
        receive do
          :continue -> prepared(inbox, ids, opts)
        after
          5000 -> {:error, :profile_unavailable}
        end

      _ ->
        prepared(inbox, ids, opts)
    end
  end

  defp prepared(inbox, ids, opts) do
    {:ok,
     fn ->
       [action] = TestRepo.all(Action, prefix: opts[:scope].prefix)

       send(
         opts[:observer],
         {:mutating, action.state, action.dispatch_started_at, TestRepo.in_transaction?()}
       )

       TestGmail.remove_inbox(inbox, ids, opts)
     end}
  end
end

defmodule EmailJanitor.PreparationTestPolicy do
  @behaviour EmailJanitor.Policy
  @impl true
  def reserve(pid, _, _, _, _) do
    send(pid, :reserved)
    :ok
  end

  @impl true
  def settle(_, _, _, _), do: :ok
  @impl true
  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.PreparationTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Executor,
    Owner,
    Policy,
    PreparedTestGmail,
    PreparationTestPolicy,
    Reviewer,
    Store,
    TestClassifier,
    TestRepo
  }

  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    messages = [message()]
    {:ok, proposal} = Reviewer.review(messages, box, MapSet.new(), {TestClassifier, []}, "", 1)
    state = start_supervised!({Agent, fn -> %{messages: messages, contacted: [], calls: []} end})
    %{scope: scope, inbox: box, proposal: proposal, state: state}
  end

  defp execute(ctx, observer, options \\ []) do
    Executor.execute(
      ctx.scope,
      ctx.inbox,
      ctx.proposal,
      {PreparedTestGmail, [state: ctx.state, scope: ctx.scope, observer: observer] ++ options},
      policy: %Policy{adapter: PreparationTestPolicy, context: observer}
    )
  end

  test "preparation precedes reservation and the durable fence precedes the prepared mutation",
       ctx do
    assert {:done, _} = execute(ctx, self())
    assert_receive {:preparing, _, false}
    assert_receive :reserved
    assert_receive {:mutating, :intent, %DateTime{}, false}
    assert [["message-1"]] = Agent.get(ctx.state, & &1.calls)
    assert [%{labels: ["UNREAD", "IMPORTANT"]}] = Agent.get(ctx.state, & &1.messages)
  end

  test "failed preparation creates no durable intent or quota reservation", ctx do
    assert {:error, :gmail_unavailable} = execute(ctx, self(), prepare: :fail)
    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [] = Agent.get(ctx.state, & &1.calls)
    refute_receive :reserved, 0
  end

  test "termination during preparation cannot strand a dispatched action or reservation", ctx do
    observer = self()
    task = Task.async(fn -> execute(ctx, observer, prepare: :block) end)
    assert_receive {:preparing, owner, false}, 1000
    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    refute_receive :reserved, 0
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1000
    assert {:error, :executor_unavailable} = Task.await(task, 1000)
    assert [] = TestRepo.all(Action, prefix: ctx.scope.prefix)
    assert [] = Agent.get(ctx.state, & &1.calls)
  end

  test "dispatch cannot begin without its full watchdog window in the overall budget" do
    observer = self()

    assert {:error, :dispatch_window_exhausted} =
             Owner.run(
               fn ->
                 Owner.bounded(fn -> send(observer, :unexpected_dispatch) end)
               end,
               5000
             )

    refute_receive :unexpected_dispatch, 0
  end
end
