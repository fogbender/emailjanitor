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

    assert {:ok, ^receipt} =
             Preferences.replace(
               ctx.scope,
               :all,
               before,
               Content.new("A different instruction."),
               id
             )

    assert {:error, :request_conflict} =
             Preferences.replace(
               ctx.scope,
               {:inbox, ctx.first.id},
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

    for invalid <- [String.duplicate("a", 15_001), <<255>>, "nul\0value", <<1>>, <<13>>, <<127>>] do
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

    handler = "preferences-query-exporter"

    :ok =
      :telemetry.attach(
        handler,
        [:email_janitor, :test_repo, :query],
        fn _, _, metadata, pid -> send(pid, {:preference_query, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    Ecto.Adapters.SQL.query!(TestRepo, "SELECT $1::text", ["QUERY_EXPORTER_CONTROL"], log: false)
    assert_receive {:preference_query, %{params: ["QUERY_EXPORTER_CONTROL"]}}

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

    refute inspect(TestRepo.all(Preferences.Row, prefix: ctx.scope.prefix, telemetry_event: nil)) =~
             "DISTILLED_PREFERENCE_PRIVATE_MARKER"

    refute logs =~ "DISTILLED_PREFERENCE_PRIVATE_MARKER"
    refute_private_queries()

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

  defp refute_private_queries do
    receive do
      {:preference_query, metadata} ->
        refute inspect(metadata) =~ "DISTILLED_PREFERENCE_PRIVATE_MARKER"
        refute_private_queries()
    after
      0 -> :ok
    end
  end

  test "clearing retains text-free recovery proof until maintenance prunes the retry window",
       ctx do
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.first.id)
    first_id = Ecto.UUID.generate()

    {:ok, _} =
      Preferences.replace(ctx.scope, :all, snapshot, Content.new("Keep known senders."), first_id)

    old = DateTime.add(DateTime.utc_now(), -604_801)

    TestRepo.get!(Preferences.Change, first_id, prefix: ctx.scope.prefix)
    |> Ecto.Changeset.change(inserted_at: old)
    |> TestRepo.update!(prefix: ctx.scope.prefix)

    assert {:ok, :ok} = Preferences.purge_receipts(ctx.scope)
    assert is_nil(TestRepo.get(Preferences.Change, first_id, prefix: ctx.scope.prefix))
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.first.id)

    second_id = Ecto.UUID.generate()

    {:ok, second_receipt} =
      Preferences.replace(
        ctx.scope,
        :all,
        snapshot,
        Content.new("Keep people I know."),
        second_id
      )

    {:ok, snapshot} = Preferences.snapshot(ctx.scope, ctx.first.id)

    assert {:ok, receipt} =
             Preferences.replace(ctx.scope, :all, snapshot, Content.new(""), Ecto.UUID.generate())

    refute Map.has_key?(Map.from_struct(receipt), :instruction_hash)

    assert MapSet.new(TestRepo.all(Preferences.Change, prefix: ctx.scope.prefix)) ==
             MapSet.new([receipt, second_receipt])

    {:ok, current} = Preferences.snapshot(ctx.scope, ctx.first.id)
    assert Content.read(current.global) == ""

    assert {:ok, ^second_receipt} =
             Preferences.replace(
               ctx.scope,
               :all,
               current,
               Content.new("Must not revive."),
               second_id
             )

    {:ok, unchanged} = Preferences.snapshot(ctx.scope, ctx.first.id)
    assert Content.read(unchanged.global) == ""
    assert unchanged.instruction_version == current.instruction_version
  end

  test "a local correction leaves another inbox's prepared action dispatchable", ctx do
    observer = self()

    prepare = fn box ->
      {:ok, proposal} =
        Reviewer.review([message()], box, MapSet.new(), {TestClassifier, []}, "", 1)

      Task.async(fn ->
        Owner.run(fn ->
          {:ok, {:created, action}} = Store.intent(ctx.scope, box.id, proposal, "100")
          send(observer, {:prepared_local, box.id, action})

          receive do
            :dispatch -> Store.begin_dispatch(ctx.scope, box.id, action.id, action.owner_token)
          after
            5000 -> {:error, :test_timeout}
          end
        end)
      end)
    end

    first = prepare.(ctx.first)
    second = prepare.(ctx.second)
    first_id = ctx.first.id
    second_id = ctx.second.id
    assert_receive {:prepared_local, ^first_id, a}, 1_000
    assert_receive {:prepared_local, ^second_id, b}, 1_000
    {:ok, snapshot} = Preferences.snapshot(ctx.scope, first_id)

    {:ok, _} =
      Preferences.replace(
        ctx.scope,
        {:inbox, first_id},
        snapshot,
        Content.new("Keep customers here."),
        Ecto.UUID.generate()
      )

    send(:erlang.binary_to_term(a.owner_beam_pid, [:safe]), :dispatch)
    send(:erlang.binary_to_term(b.owner_beam_pid, [:safe]), :dispatch)
    assert {:error, :proposal_changed} = Task.await(first)
    assert :ok = Task.await(second)
    assert is_nil(Store.get(ctx.scope, first_id, a.id).dispatch_started_at)
    assert %DateTime{} = Store.get(ctx.scope, second_id, b.id).dispatch_started_at
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
