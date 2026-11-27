defmodule EmailJanitor.DigestStagingRecoveryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import EmailJanitor.Fixtures

  alias EmailJanitor.{
    Digest,
    DigestStagePolicy,
    Inbox,
    Policy,
    Reviewer,
    Store,
    TestClassifier,
    TestRepo
  }

  alias EmailJanitor.Digest.{Activity, Staged}
  alias EmailJanitor.Store.Scope

  defp database(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  setup do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    {:ok, box} = Inbox.new("stage-" <> suffix, "owner-" <> suffix <> "@example.com")
    {:ok, scope} = Scope.new(TestRepo, "ej_digest_stage_concurrency")

    headers =
      Map.new(["a1", "a2"], &{&1, %{sender: "sender@example.com", subject: "Subject " <> &1}})

    messages = for id <- ["a1", "a2"], do: message(id: id)
    {:ok, proposal} = Reviewer.review(messages, box, MapSet.new(), {TestClassifier, []}, "", 1)

    action =
      database(fn ->
        {:ok, _} = Store.add_inbox(scope, box)
        policy = %Policy{adapter: DigestStagePolicy, context: %{scope: scope, headers: headers}}
        {:ok, {:created, action}} = Store.intent(scope, box.id, proposal, "100", policy: policy)
        # A synthetic durable Gmail result; no network calls are made in this test.
        :ok = Store.transition(scope, box.id, action.id, :intent, :done)
        action
      end)

    %{scope: scope, inbox: box, action: action, suffix: suffix}
  end

  test "independent settlement connections promote each exact message once", ctx do
    results =
      1..16
      |> Task.async_stream(
        fn _ ->
          database(fn -> Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id) end)
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))

    database(fn ->
      assert TestRepo.aggregate(from(a in Activity, where: a.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 2

      assert TestRepo.aggregate(from(s in Staged, where: s.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 0
    end)
  end

  test "killing confirmation after its first insert rolls back promotion and retains repair metadata",
       ctx do
    # A test-only PostgreSQL trigger blocks the second insert on an advisory lock.
    # This proves rollback on actual process death without a production test hook.
    key = :erlang.phash2(ctx.suffix)
    function = "stage_block_" <> ctx.suffix

    database(fn ->
      TestRepo.query!(
        """
        CREATE FUNCTION #{ctx.scope.prefix}.#{function}() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.inbox_id = '#{ctx.inbox.id}' AND NEW.message_id = 'a2' THEN
            PERFORM pg_advisory_xact_lock(#{key});
          END IF;
          RETURN NEW;
        END $$
        """,
        [],
        log: false
      )

      TestRepo.query!(
        "CREATE TRIGGER #{function} BEFORE INSERT ON #{ctx.scope.prefix}.digest_activity FOR EACH ROW EXECUTE FUNCTION #{ctx.scope.prefix}.#{function}()",
        [],
        log: false
      )
    end)

    on_exit(fn ->
      database(fn ->
        TestRepo.query!(
          "DROP TRIGGER IF EXISTS #{function} ON #{ctx.scope.prefix}.digest_activity",
          [],
          log: false
        )

        TestRepo.query!("DROP FUNCTION IF EXISTS #{ctx.scope.prefix}.#{function}()", [],
          log: false
        )
      end)
    end)

    parent = self()

    {locker, locker_monitor} =
      spawn_monitor(fn ->
        database(fn ->
          TestRepo.transaction(fn ->
            TestRepo.query!("SELECT pg_advisory_xact_lock($1)", [key], log: false)
            send(parent, {:barrier_locked, self()})

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    on_exit(fn -> send(locker, :release) end)
    assert_receive {:barrier_locked, ^locker}, 5000

    {pid, monitor} =
      spawn_monitor(fn ->
        database(fn ->
          [[backend]] = TestRepo.query!("SELECT pg_backend_pid()", [], log: false).rows
          send(parent, {:promoting, backend})
          Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)
        end)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:promoting, backend}, 5000
    assert wait_for_lock(backend, 200)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5000
    send(locker, :release)
    assert_receive {:DOWN, ^locker_monitor, :process, ^locker, :normal}, 5000

    database(fn ->
      assert TestRepo.aggregate(from(a in Activity, where: a.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 0

      assert TestRepo.aggregate(from(s in Staged, where: s.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 2

      assert :ok = Digest.confirm_staged(ctx.scope, ctx.inbox.id, ctx.action.id)

      assert TestRepo.aggregate(from(a in Activity, where: a.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 2
    end)
  end

  defp wait_for_lock(_, 0), do: false

  defp wait_for_lock(backend, remaining) do
    rows =
      database(fn ->
        TestRepo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend],
          log: false
        ).rows
      end)

    if rows == [["Lock"]],
      do: true,
      else:
        (
          Process.sleep(10)
          wait_for_lock(backend, remaining - 1)
        )
  end
end
