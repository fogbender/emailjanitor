defmodule EmailJanitor.MailDisconnectRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias EmailJanitor.{Inbox, Store, TestRepo}
  alias EmailJanitor.Mail.{Outbox, Outgoing}
  alias EmailJanitor.MailFixture, as: F
  alias EmailJanitor.Store.{Mailbox, Scope}

  defp database(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fun)

  test "disconnect committing while preparation runs blocks dispatch under the mailbox fence" do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    {:ok, inbox} = Inbox.new("mail-race-" <> suffix, "owner-" <> suffix <> "@example.com")
    {:ok, scope} = Scope.new(TestRepo, "ej_recovery")

    row =
      database(fn ->
        {:ok, _} = Store.add_inbox(scope, inbox)

        Ecto.Adapters.SQL.query!(
          TestRepo,
          "CREATE TABLE IF NOT EXISTS #{scope.prefix}.mail_connections (inbox_id text PRIMARY KEY, active boolean NOT NULL)",
          [],
          log: false
        )

        TestRepo.insert_all("mail_connections", [%{inbox_id: inbox.id, active: true}],
          prefix: scope.prefix
        )

        {:ok, row} =
          Outbox.enqueue(
            scope,
            inbox.id,
            :assistant,
            [Ecto.UUID.generate()],
            Ecto.UUID.generate()
          )

        row
      end)

    parent = self()

    {disconnect, monitor} =
      spawn_monitor(fn ->
        database(fn ->
          TestRepo.transaction(fn ->
            TestRepo.one!(from(m in Mailbox, where: m.id == ^inbox.id, lock: "FOR UPDATE"),
              prefix: scope.prefix
            )

            TestRepo.update_all(
              from(c in "mail_connections", where: c.inbox_id == ^inbox.id),
              [set: [active: false]],
              prefix: scope.prefix
            )

            send(parent, {:disconnect_locked, self()})

            receive do
              :release -> :ok
            after
              5000 -> :ok
            end
          end)
        end)
      end)

    on_exit(fn -> send(disconnect, :release) end)
    assert_receive {:disconnect_locked, ^disconnect}, 5000

    base =
      F.config(fn _ ->
        send(parent, :unexpected_send)
        raise "must not send"
      end)

    credentials = base.credentials

    config = %{
      base
      | credentials: fn ->
          [[backend]] =
            Ecto.Adapters.SQL.query!(TestRepo, "SELECT pg_backend_pid()", [], log: false).rows

          send(parent, {:prepared, backend})
          credentials.()
        end
    }

    authorize = fn _ ->
      case TestRepo.one(
             from(c in "mail_connections", where: c.inbox_id == ^inbox.id, select: c.active),
             prefix: scope.prefix
           ) do
        true -> {:ok, inbox}
        _ -> {:error, :disconnected}
      end
    end

    sender =
      Task.async(fn ->
        database(fn ->
          Outbox.deliver(scope, row.id, config, authorize, fn _ -> {:ok, F.message()} end)
        end)
      end)

    assert_receive {:prepared, backend}, 5000
    assert wait_for_lock(backend, 100)
    send(disconnect, :release)
    assert_receive {:DOWN, ^monitor, :process, ^disconnect, :normal}, 5000
    assert {:error, :mail_unavailable} = Task.await(sender, 5000)
    refute_received :unexpected_send

    database(fn ->
      assert TestRepo.get!(Outgoing, row.id, prefix: scope.prefix).state == :pending
    end)
  end

  defp wait_for_lock(_, 0), do: false

  defp wait_for_lock(backend, remaining) do
    waiting =
      database(fn ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
          [backend],
          log: false
        ).rows
      end)

    if waiting == [["Lock"]] do
      true
    else
      Process.sleep(10)
      wait_for_lock(backend, remaining - 1)
    end
  end
end
