defmodule EmailJanitor.PreferenceBarrierPolicy do
  @behaviour EmailJanitor.Policy
  @impl true
  def reserve(observer, _, _, _, _) do
    send(observer, {:preference_reservation, self()})

    receive do
      :continue -> :ok
    after
      5000 -> {:error, :test_timeout}
    end
  end

  @impl true
  def settle(observer, _, _, result),
    do:
      (
        send(observer, {:preference_settled, result})
        :ok
      )

  @impl true
  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.PreferencesExecutionTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Content,
    Executor,
    Policy,
    Preferences,
    PreferenceBarrierPolicy,
    Reviewer,
    Store,
    TestClassifier,
    TestGmail,
    TestRepo
  }

  alias EmailJanitor.Store.{Action, Candidate, Mailbox, Scope}

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  setup do
    {:ok, scope} = Scope.new(TestRepo, "ej_preferences_concurrency")
    box = inbox()
    unboxed(fn -> {:ok, _} = Store.add_inbox(scope, box) end)

    on_exit(fn ->
      unboxed(fn ->
        for schema <- [Preferences.Change, Preferences.Row, Candidate, Action, Mailbox],
            do: TestRepo.delete_all(schema, prefix: scope.prefix)
      end)
    end)

    %{scope: scope, inbox: box}
  end

  test "Executor cancels and settles an intent after a newer correction, without calling Gmail",
       ctx do
    messages = [message()]
    state = start_supervised!({Agent, fn -> %{messages: messages, contacted: [], calls: []} end})

    {:ok, proposal} =
      Reviewer.review(messages, ctx.inbox, MapSet.new(), {TestClassifier, []}, "", 1)

    {:ok, snapshot} = unboxed(fn -> Preferences.snapshot(ctx.scope, ctx.inbox.id) end)
    observer = self()

    execution =
      Task.async(fn ->
        unboxed(fn ->
          Executor.execute(ctx.scope, ctx.inbox, proposal, {TestGmail, [state: state]},
            policy: %Policy{adapter: PreferenceBarrierPolicy, context: observer}
          )
        end)
      end)

    assert_receive {:preference_reservation, owner}, 1000

    correction =
      Task.async(fn ->
        unboxed(fn ->
          Preferences.replace(
            ctx.scope,
            :all,
            snapshot,
            Content.new("Keep this type of email."),
            Ecto.UUID.generate()
          )
        end)
      end)

    # Establish a real DB waiter before releasing the intent transaction. The
    # correction therefore owns the mailbox before the subsequent dispatch fence.
    wait_for_database_lock(200)
    send(owner, :continue)
    assert {:ok, _} = Task.await(correction)
    assert {:error, :proposal_changed} = Task.await(execution)
    assert_receive {:preference_settled, {:reconciled, [], ["message-1"]}}
    [action] = unboxed(fn -> TestRepo.all(Action, prefix: ctx.scope.prefix) end)
    assert action.state == :cancelled
    assert is_nil(action.dispatch_started_at)
    assert Agent.get(state, & &1.calls) == []
    assert [%{labels: ["INBOX", "UNREAD", "IMPORTANT"]}] = Agent.get(state, & &1.messages)
  end

  defp wait_for_database_lock(0), do: flunk("Correction never waited on the mailbox lock")

  defp wait_for_database_lock(attempts) do
    waiting =
      unboxed(fn ->
        %{rows: [[count]]} =
          Ecto.Adapters.SQL.query!(
            TestRepo,
            "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()",
            [],
            log: false
          )

        count > 0
      end)

    if !waiting do
      Process.sleep(5)
      wait_for_database_lock(attempts - 1)
    end
  end

  test "local correction completes while another inbox is locked, while a global correction waits",
       ctx do
    {:ok, other} = EmailJanitor.Inbox.new("locked-other", "other@example.com")
    unboxed(fn -> {:ok, _} = Store.add_inbox(ctx.scope, other) end)
    {:ok, initial} = unboxed(fn -> Preferences.snapshot(ctx.scope, ctx.inbox.id) end)
    observer = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          TestRepo.transaction(fn ->
            Ecto.Adapters.SQL.query!(
              TestRepo,
              "SELECT id FROM ej_preferences_concurrency.inboxes WHERE id=$1 FOR UPDATE",
              [other.id],
              log: false
            )

            send(observer, :other_mailbox_locked)

            receive do
              :release -> :ok
            after
              5000 -> TestRepo.rollback(:test_timeout)
            end
          end)
        end)
      end)

    assert_receive :other_mailbox_locked

    local =
      Task.async(fn ->
        unboxed(fn ->
          Preferences.replace(
            ctx.scope,
            {:inbox, ctx.inbox.id},
            initial,
            Content.new("Only this inbox."),
            Ecto.UUID.generate()
          )
        end)
      end)

    result = Task.yield(local, 1000)

    if is_nil(result) do
      send(holder.pid, :release)
      Task.await(holder)
      Task.await(local)
      flunk("A local correction waited on another inbox's lock")
    end

    assert {:ok, {:ok, _}} = result
    {:ok, current} = unboxed(fn -> Preferences.snapshot(ctx.scope, ctx.inbox.id) end)

    global =
      Task.async(fn ->
        unboxed(fn ->
          Preferences.replace(
            ctx.scope,
            :all,
            current,
            Content.new("All inboxes."),
            Ecto.UUID.generate()
          )
        end)
      end)

    wait_for_database_lock(200)
    assert is_nil(Task.yield(global, 10))
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
    assert {:ok, _} = Task.await(global)
  end

  test "concurrent snapshots never combine preference text and versions from different commits",
       ctx do
    observer = self()

    writer =
      Task.async(fn ->
        unboxed(fn ->
          receive do
            :start -> :ok
          end

          for n <- 1..20 do
            {:ok, current} = Preferences.snapshot(ctx.scope, ctx.inbox.id)

            {:ok, _} =
              Preferences.replace(
                ctx.scope,
                :all,
                current,
                Content.new("g#{n}"),
                Ecto.UUID.generate()
              )

            Process.sleep(2)
          end

          send(observer, :writer_done)
        end)
      end)

    reader =
      Task.async(fn ->
        unboxed(fn ->
          receive do
            :start -> :ok
          end

          for _ <- 1..40 do
            {:ok, current} = Preferences.snapshot(ctx.scope, ctx.inbox.id)
            assert current.instruction_version == current.global_revision + 1

            expected =
              if current.global_revision == 0, do: "", else: "g#{current.global_revision}"

            assert Content.read(current.global) == expected
            Process.sleep(2)
            current.global_revision
          end
        end)
      end)

    send(writer.pid, :start)
    send(reader.pid, :start)
    observations = Task.await(reader)
    assert length(Enum.uniq(observations)) > 1
    Task.await(writer)
    assert_receive :writer_done
  end
end
