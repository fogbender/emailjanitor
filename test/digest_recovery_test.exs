defmodule EmailJanitor.DigestRecoveryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias EmailJanitor.{Digest, Inbox, Store, TestRepo}
  alias EmailJanitor.Digest.{Activity, Event, Schedule, Snapshot}
  alias EmailJanitor.Mail.{Outbox, Outgoing}
  alias EmailJanitor.MailFixture, as: F
  alias EmailJanitor.Store.Scope
  @due ~U[2026-11-20 21:00:00Z]

  defp database(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  setup do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    {:ok, inbox} = Inbox.new("digest-" <> suffix, "owner-" <> suffix <> "@example.com")
    {:ok, scope} = Scope.new(TestRepo, "ej_digest_concurrency")

    database(fn ->
      {:ok, _} = Store.add_inbox(scope, inbox)
      :ok = Digest.configure(scope, inbox.id, "Etc/UTC", ~U[2026-11-20 12:00:00Z])

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "CREATE TABLE IF NOT EXISTS #{scope.prefix}.digest_host_claims (message_id text PRIMARY KEY, digest_id text)",
        [],
        log: false
      )
    end)

    %{scope: scope, inbox: inbox}
  end

  defp event(ctx, kind, id) do
    {:ok, event} =
      Event.new(
        Ecto.UUID.generate(),
        id,
        kind,
        "sender@example.com",
        "Recovery subject",
        ~U[2026-11-20 20:00:00Z]
      )

    database(fn -> Digest.record(ctx.scope, ctx.inbox.id, event) end)
  end

  test "independent connections create only one snapshot and outbox intention", ctx do
    {:ok, _} = event(ctx, :done, "a1")

    results =
      1..16
      |> Task.async_stream(
        fn _ -> database(fn -> Digest.tick(ctx.scope, ctx.inbox.id, @due) end) end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, {:ready, _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, :not_due})) == 15

    database(fn ->
      assert TestRepo.aggregate(from(d in Snapshot, where: d.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 1

      assert TestRepo.aggregate(from(o in Outgoing, where: o.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 1
    end)
  end

  test "crash during host extra claim rolls back its side effect and recovers cleanly", ctx do
    message_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    {:ok, activity} = event(ctx, :would_have_done, message_id)
    parent = self()

    claim = fn _inbox, digest, _cutoff, ids ->
      TestRepo.insert_all(
        "digest_host_claims",
        Enum.map(ids, &%{message_id: &1, digest_id: digest}),
        prefix: ctx.scope.prefix
      )

      send(parent, {:inside_claim, self()})

      receive do
        :continue -> {:ok, ids}
      end
    end

    {pid, monitor} =
      spawn_monitor(fn ->
        database(fn -> Digest.tick(ctx.scope, ctx.inbox.id, @due, claim) end)
      end)

    assert_receive {:inside_claim, ^pid}, 5000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5000

    database(fn ->
      assert TestRepo.aggregate(
               from(c in "digest_host_claims", where: c.message_id == ^message_id),
               :count,
               prefix: ctx.scope.prefix
             ) == 0

      assert TestRepo.get!(Activity, activity.id, prefix: ctx.scope.prefix).digest_id == nil

      assert TestRepo.aggregate(from(o in Outgoing, where: o.inbox_id == ^ctx.inbox.id), :count,
               prefix: ctx.scope.prefix
             ) == 0

      assert {:ok, {:ready, _}} =
               Digest.tick(ctx.scope, ctx.inbox.id, @due, fn _, _, _, ids -> {:ok, ids} end)
    end)
  end

  test "crash after send fence retains local-day reservation and never resends", ctx do
    {:ok, _} = event(ctx, :done, "b1")
    {:ok, {:ready, snapshot}} = database(fn -> Digest.tick(ctx.scope, ctx.inbox.id, @due) end)
    config = F.config(fn _ -> Process.exit(self(), :kill) end)

    result =
      database(fn ->
        Digest.deliver(ctx.scope, snapshot.id, config, fn _ -> {:ok, ctx.inbox} end,
          clock: fn -> @due end
        )
      end)

    assert {:error, :executor_unavailable} = result

    database(fn ->
      assert Outbox.get(ctx.scope, snapshot.outbox_id).state == :dispatching

      assert TestRepo.get!(Schedule, ctx.inbox.id, prefix: ctx.scope.prefix).delivery_digest_id ==
               snapshot.id

      assert {:error, :unresolved_delivery} =
               Digest.deliver(
                 ctx.scope,
                 snapshot.id,
                 F.config(fn _ -> flunk("replayed ambiguous send") end),
                 fn _ -> {:ok, ctx.inbox} end,
                 clock: fn -> @due end
               )
    end)
  end
end
