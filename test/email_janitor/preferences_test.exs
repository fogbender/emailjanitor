defmodule EmailJanitor.PreferencesTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  import ExUnit.CaptureLog

  alias EmailJanitor.{
    Content,
    Executor,
    Inbox,
    Owner,
    Preferences,
    Reviewer,
    Store,
    TestClassifier,
    TestRepo
  }

  alias EmailJanitor.Store.{Action, Scope}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    first = inbox()
    {:ok, second} = Inbox.new("second", "owner@second.example.com")
    {:ok, _} = Store.add_inbox(scope, first)
    {:ok, _} = Store.add_inbox(scope, second)
    %{scope: scope, first: first, second: second}
  end

  test "global corrections affect every inbox; local exceptions affect only the selected inbox",
       ctx do
    {:ok, initial} = Preferences.snapshot(ctx.scope, ctx.first.id)

    assert {:ok, %{revision: 1, changed: true}} =
             Preferences.replace(
               ctx.scope,
               :all,
               initial,
               Content.new("Mark unsolicited podcast invitations Done."),
               Ecto.UUID.generate()
             )

    {:ok, one} = Preferences.snapshot(ctx.scope, ctx.first.id)
    {:ok, two} = Preferences.snapshot(ctx.scope, ctx.second.id)
    assert one.instruction_version == 2
    assert two.instruction_version == 2
    assert Content.read(one.global) == Content.read(two.global)

    assert {:ok, _} =
             Preferences.replace(
               ctx.scope,
               {:inbox, ctx.first.id},
               one,
               Content.new("Keep requested customer comparisons."),
               Ecto.UUID.generate()
             )

    {:ok, one} = Preferences.snapshot(ctx.scope, ctx.first.id)
    {:ok, two} = Preferences.snapshot(ctx.scope, ctx.second.id)
    assert one.instruction_version == 3
    assert two.instruction_version == 2
    assert Content.read(one.local) =~ "customer comparisons"
    assert Content.read(two.local) == ""
    assert Content.read(Preferences.text(one)) =~ "podcast invitations"
  end

  test "stale updates cannot overwrite a later correction and request receipts deduplicate retries",
       ctx do
    {:ok, before} = Preferences.snapshot(ctx.scope, ctx.first.id)
    id = Ecto.UUID.generate()
    instruction = Content.new("Keep people I have corresponded with.")
    assert {:ok, receipt} = Preferences.replace(ctx.scope, :all, before, instruction, id)
    assert {:ok, ^receipt} = Preferences.replace(ctx.scope, :all, before, instruction, id)

    assert {:error, :request_conflict} =
             Preferences.replace(
               ctx.scope,
               :all,
               before,
               Content.new("A different instruction."),
               id
             )

    assert {:error, :instructions_changed} =
             Preferences.replace(
               ctx.scope,
               :all,
               before,
               Content.new("An older model result."),
               Ecto.UUID.generate()
             )

    {:ok, current} = Preferences.snapshot(ctx.scope, ctx.first.id)

    assert {:ok, %{changed: false, revision: 1}} =
             Preferences.replace(ctx.scope, :all, current, instruction, Ecto.UUID.generate())

    assert {:ok, %{instruction_version: 2}} = Preferences.snapshot(ctx.scope, ctx.first.id)
  end

  test "snapshots and writes are scoped, validated and bounded below the model context budget",
       ctx do
    {:ok, before} = Preferences.snapshot(ctx.scope, ctx.first.id)
    {:ok, other_scope} = Scope.new(TestRepo, "ej_test_b")
    assert {:error, :unknown_inbox} = Preferences.snapshot(other_scope, ctx.first.id)

    assert {:error, :invalid_instruction} =
             Preferences.replace(
               other_scope,
               :all,
               before,
               Content.new("An instruction."),
               Ecto.UUID.generate()
             )

    assert {:error, :invalid_instruction} =
             Preferences.replace(
               ctx.scope,
               {:inbox, ctx.second.id},
               before,
               Content.new("An instruction."),
               Ecto.UUID.generate()
             )

    for invalid <- [String.duplicate("a", 15_001), <<255>>, "nul\0value"] do
      assert {:error, :invalid_instruction} =
               Preferences.replace(
                 ctx.scope,
                 :all,
                 before,
                 Content.new(invalid),
                 Ecto.UUID.generate()
               )
    end

    assert {:ok, _} =
             Preferences.replace(
               ctx.scope,
               :all,
               before,
               Content.new(String.duplicate("g", 15_000)),
               Ecto.UUID.generate()
             )

    {:ok, before} = Preferences.snapshot(ctx.scope, ctx.first.id)

    assert {:ok, _} =
             Preferences.replace(
               ctx.scope,
               {:inbox, ctx.first.id},
               before,
               Content.new(String.duplicate("l", 15_000)),
               Ecto.UUID.generate()
             )

    {:ok, after_change} = Preferences.snapshot(ctx.scope, ctx.first.id)
    assert byte_size(Content.read(Preferences.text(after_change))) < 32_000
  end

  test "instruction text is redacted in snapshots, rows, receipts and database logs", ctx do
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.first.id)

    logs =
      capture_log(fn ->
        assert {:ok, receipt} =
                 Preferences.replace(
                   ctx.scope,
                   :all,
                   snapshot,
                   Content.new("DISTILLED_PREFERENCE_PRIVATE_MARKER"),
                   Ecto.UUID.generate()
                 )

        refute inspect(receipt) =~ "DISTILLED_PREFERENCE_PRIVATE_MARKER"
      end)

    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.first.id)
    refute inspect(snapshot) =~ "DISTILLED_PREFERENCE_PRIVATE_MARKER"

    refute inspect(TestRepo.all(Preferences.Row, prefix: ctx.scope.prefix)) =~
             "DISTILLED_PREFERENCE_PRIVATE_MARKER"

    refute logs =~ "DISTILLED_PREFERENCE_PRIVATE_MARKER"

    assert {:ok, {:error, :outer_transaction}} =
             TestRepo.transaction(fn ->
               Preferences.replace(
                 ctx.scope,
                 :all,
                 snapshot,
                 Content.new("An instruction."),
                 Ecto.UUID.generate()
               )
             end)
  end

  test "a correction committed after intent prevents that old action crossing its dispatch fence",
       ctx do
    {:ok, proposal} =
      Reviewer.review([message()], ctx.first, MapSet.new(), {TestClassifier, []}, "", 1)

    observer = self()

    task =
      Task.async(fn ->
        Owner.run(fn ->
          {:ok, {:created, action}} = Store.intent(ctx.scope, ctx.first.id, proposal, "100")
          send(observer, {:prepared_action, action})

          receive do
            :dispatch ->
              Store.begin_dispatch(ctx.scope, ctx.first.id, action.id, action.owner_token)
          after
            5000 -> {:error, :test_timeout}
          end
        end)
      end)

    assert_receive {:prepared_action, action}
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.first.id)

    assert {:ok, _} =
             Preferences.replace(
               ctx.scope,
               :all,
               snapshot,
               Content.new("Keep this type of email."),
               Ecto.UUID.generate()
             )

    send_owner = :erlang.binary_to_term(action.owner_beam_pid, [:safe])
    send(send_owner, :dispatch)
    assert {:error, :proposal_changed} = Task.await(task)
    assert is_nil(Store.get(ctx.scope, ctx.first.id, action.id).dispatch_started_at)
    assert {:ok, _} = Executor.recover(ctx.scope, ctx.first, action.id)
    assert Store.get(ctx.scope, ctx.first.id, action.id).state == :cancelled
    assert TestRepo.all(Action, prefix: ctx.scope.prefix) |> length() == 1
  end
end

defmodule EmailJanitor.PreferencesRegistrationTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Content, Inbox, Preferences, Store, TestRepo}
  alias EmailJanitor.Store.Scope

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  test "an inbox registration cannot slip past a concurrent global version update" do
    {:ok, scope} = Scope.new(TestRepo, "ej_preferences_concurrency")
    first = inbox()
    {:ok, second} = Inbox.new("new-box", "new@example.com")

    unboxed(fn ->
      {:ok, _} = Store.add_inbox(scope, first)
    end)

    on_exit(fn ->
      unboxed(fn ->
        for schema <- [Preferences.Change, Preferences.Row, EmailJanitor.Store.Mailbox],
            do: TestRepo.delete_all(schema, prefix: scope.prefix)
      end)
    end)

    {:ok, snapshot} = unboxed(fn -> Preferences.snapshot(scope, first.id) end)
    observer = self()

    registration =
      Task.async(fn ->
        unboxed(fn ->
          TestRepo.transaction(fn ->
            {:ok, _} = Store.add_inbox(scope, second)
            send(observer, :registered_uncommitted)

            receive do
              :commit -> :ok
            after
              5000 -> TestRepo.rollback(:test_timeout)
            end
          end)
        end)
      end)

    assert_receive :registered_uncommitted

    correction =
      Task.async(fn ->
        unboxed(fn ->
          result =
            Preferences.replace(
              scope,
              :all,
              snapshot,
              Content.new("Keep known people."),
              Ecto.UUID.generate()
            )

          send(observer, :correction_completed)
          result
        end)
      end)

    refute_receive :correction_completed, 100
    send(registration.pid, :commit)
    assert {:ok, :ok} = Task.await(registration)
    assert {:ok, _} = Task.await(correction)
    {:ok, current} = unboxed(fn -> Preferences.snapshot(scope, second.id) end)
    assert current.instruction_version == 2
    assert Content.read(current.global) == "Keep known people."
  end
end
