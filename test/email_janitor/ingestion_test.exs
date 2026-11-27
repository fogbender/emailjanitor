defmodule EmailJanitor.IngestionTest.Gmail do
  def history(_inbox, cursor, opts), do: opts[:history].(cursor)
  def thread_id(_inbox, message_id, opts), do: opts[:thread_id].(message_id)
  def thread(_inbox, thread_id, opts), do: opts[:thread].(thread_id)
  def renew_watch(_inbox, topic, opts), do: opts[:renew].(topic)
end

defmodule EmailJanitor.IngestionTest.PubSub do
  def pull(config), do: {:ok, config[:deliveries]}
  def acknowledge(config, [delivery]), do: config[:ack].(delivery)
end

defmodule EmailJanitor.IngestionTest.MigrationRepo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.IngestionTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, Fixtures, Store, TestRepo, Proposal}
  alias EmailJanitor.Gmail.{Ingestion, NotificationWorker}
  alias Ingestion.{Arrival, Checkpoint}
  alias EmailJanitor.Google.PubSub.Delivery
  alias EmailJanitor.Store.Scope
  alias EmailJanitor.IngestionTest.{Gmail, PubSub, MigrationRepo}
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    start_supervised!(
      {MigrationRepo,
       [
         socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
         database: "emailjanitor_test",
         username: System.fetch_env!("USER"),
         port: 5432,
         pool_size: 2,
         log: false
       ]}
    )

    :ok
  end

  setup do
    # Each test uses a committed throwaway schema: acknowledgements and races
    # exercise real independent database transactions, not nested sandbox saves.
    prefix = "ej_ingest_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, installer} = Scope.new(MigrationRepo, prefix)
    assert :ok = Ingestion.install(installer)
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    {:ok, scope} = Scope.new(TestRepo, prefix)
    box = Fixtures.inbox()
    assert {:ok, _} = Store.add_inbox(scope, box)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(MigrationRepo, ~s(DROP SCHEMA "#{prefix}" CASCADE), [], log: false)
    end)

    {:ok, scope: scope, box: box}
  end

  defp watch(cursor \\ "100"),
    do: %{history_id: cursor, expires_at: DateTime.add(DateTime.utc_now(), 86_400)}

  defp history(ids, cursor \\ "102"),
    do: %{
      complete?: true,
      history_id: cursor,
      started_at: DateTime.utc_now(),
      added_message_ids: ids,
      deleted_message_ids: [],
      events: []
    }

  defp gmail(fun), do: {Gmail, [history: fun]}

  defp baseline(scope, box, cursor \\ "100") do
    assert {:ok, checkpoint} = Ingestion.baseline(scope, box, watch(cursor))
    checkpoint
  end

  defp delivery(id \\ "102"),
    do: %Delivery{
      subscription: "projects/fixture/subscriptions/mailbox",
      ack_id: Content.new("ACK_SENTINEL"),
      message_id: "pubsub-id",
      email_address: "owner@acme.com",
      history_id: id
    }

  defp proposal(ids),
    do: %Proposal{
      thread_id: "thread-1",
      message_ids: ids,
      fingerprint: "fingerprint",
      instruction_version: 1,
      category: "cold_outreach"
    }

  test "first connection is a baseline only and restart cannot reset it", %{
    scope: scope,
    box: box
  } do
    checkpoint = baseline(scope, box)
    assert checkpoint.cursor == "100" and checkpoint.baseline_id == "100"
    assert {:ok, []} = Ingestion.pending(scope, box)
    assert {:error, :generation_changed} = Ingestion.baseline(scope, box, watch("999"))
    assert {:ok, restarted} = Ingestion.checkpoint(scope, box.id)
    assert restarted.generation == checkpoint.generation and restarted.cursor == "100"
    assert {:error, :wrong_inbox} = Ingestion.baseline(scope, %{box | id: "unknown"}, watch())
  end

  test "signals coalesce numerically without advancing the processing cursor", %{
    scope: scope,
    box: box
  } do
    baseline(scope, box, "9")

    for hint <- ["102", "10", "101", "102", "8"] do
      assert {:ok, :ok} = Ingestion.record_signal(scope, box, hint)
    end

    assert {:ok, checkpoint} = Ingestion.checkpoint(scope, box.id)
    assert checkpoint.cursor == "9" and checkpoint.requested_id == "102"
    assert {:ok, []} = Ingestion.pending(scope, box)
    assert {:error, :invalid_history_id} = Ingestion.record_signal(scope, box, "102 OR anything")
  end

  test "revoked credentials and ordinary reconsent resume the same baseline and generation", %{
    scope: scope,
    box: box
  } do
    first = baseline(scope, box)

    assert {:ok, _} =
             Ingestion.catch_up(scope, box, gmail(fn "100" -> {:ok, history(["message-1"])} end))

    assert {:error, :gmail_unavailable} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn "102" -> {:error, :authorization_required} end)
             )

    assert {:ok, _} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn "102" -> {:ok, history(["message-2"], "103")} end)
             )

    assert {:ok, checkpoint} = Ingestion.checkpoint(scope, box.id)

    assert checkpoint.generation == first.generation and checkpoint.baseline_id == "100" and
             checkpoint.cursor == "103"

    assert {:ok, pending} = Ingestion.pending(scope, box)
    assert Enum.map(pending, & &1.message_id) == ["message-1", "message-2"]
  end

  test "complete history queues exact new IDs once and preserves newer wake-up signals", %{
    scope: scope,
    box: box
  } do
    baseline(scope, box)
    assert {:ok, :ok} = Ingestion.record_signal(scope, box, "103")

    assert {:ok, %{cursor: "102", discovered_count: 2}} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn "100" -> {:ok, history(["message-1", "message-1", "message-2"])} end)
             )

    assert {:ok, pending} = Ingestion.pending(scope, box)
    assert Enum.map(pending, & &1.message_id) == ["message-1", "message-2"]
    assert {:ok, checkpoint} = Ingestion.checkpoint(scope, box.id)
    assert checkpoint.cursor == "102" and checkpoint.requested_id == "103"

    assert {:ok, %{discovered_count: 0}} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn "102" -> {:ok, history(["message-2"], "103")} end)
             )

    assert {:ok, checkpoint} = Ingestion.checkpoint(scope, box.id)
    assert checkpoint.requested_id == nil
    assert {:ok, two} = Ingestion.pending(scope, box)
    assert length(two) == 2
  end

  test "incomplete, regressing, malformed and preconnection snapshots never advance or queue", %{
    scope: scope,
    box: box
  } do
    baseline(scope, box)

    for snapshot <- [
          %{complete?: false, reason: :page_limit},
          %{complete?: false, reason: :page_loop},
          %{history(["message-1"]) | history_id: "99"},
          %{history(["message-1"]) | started_at: ~U[2000-01-01 00:00:00Z]},
          %{history(["message-1"]) | added_message_ids: ["../unsafe"]}
        ] do
      assert {:error, _} = Ingestion.catch_up(scope, box, gmail(fn _ -> {:ok, snapshot} end))

      assert {:ok, %Checkpoint{cursor: "100", status: :active}} =
               Ingestion.checkpoint(scope, box.id)

      assert {:ok, []} = Ingestion.pending(scope, box)
    end
  end

  test "expired history pauses cleanup; explicit reconnect leaves the missed backlog untouched",
       %{scope: scope, box: box} do
    first = baseline(scope, box)

    assert {:ok, _} =
             Ingestion.catch_up(scope, box, gmail(fn _ -> {:ok, history(["message-1"])} end))

    assert {:error, :history_gap} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn _ -> {:ok, %{complete?: false, reason: :history_expired}} end)
             )

    assert {:error, :history_gap} = Ingestion.pending(scope, box)

    assert {:error, :history_gap} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn _ -> flunk("gap must not fetch history") end)
             )

    assert {:error, :history_gap} = Ingestion.record_signal(scope, box, "200")
    assert {:ok, reconnected} = Ingestion.reconnect(scope, box, first.generation, watch("300"))
    refute reconnected.generation == first.generation
    assert reconnected.cursor == "300" and reconnected.baseline_id == "300"
    assert {:ok, []} = Ingestion.pending(scope, box)

    assert {:error, :generation_changed} =
             Ingestion.reconnect(scope, box, first.generation, watch("400"))

    assert {:ok, _} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn "300" -> {:ok, history(["message-2"], "301")} end)
             )

    assert {:ok, [%Arrival{message_id: "message-2"}]} = Ingestion.pending(scope, box)
  end

  test "renewal updates only expiration, including when catchup advances during its request", %{
    scope: scope,
    box: box
  } do
    before = baseline(scope, box)
    assert {:ok, :ok} = Ingestion.record_signal(scope, box, "103")

    adapter =
      {Gmail,
       [
         renew: fn "configured-topic" ->
           assert {:ok, _} =
                    Ingestion.catch_up(
                      scope,
                      box,
                      gmail(fn "100" -> {:ok, history(["message-1"])} end)
                    )

           {:ok, watch("999")}
         end
       ]}

    assert {:ok, after_renewal} = Ingestion.renew_watch(scope, box, "configured-topic", adapter)
    assert after_renewal.cursor == "102" and after_renewal.requested_id == "103"
    assert after_renewal.baseline_id == "100" and after_renewal.generation == before.generation
    assert DateTime.compare(after_renewal.watch_expires_at, before.watch_expires_at) == :gt
  end

  test "database rejection rolls back both queued IDs and cursor", %{scope: scope, box: box} do
    baseline(scope, box)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      ~s|ALTER TABLE "#{scope.prefix}".gmail_arrivals ADD CONSTRAINT reject_synthetic_message CHECK (message_id <> 'blocked')|,
      [],
      log: false
    )

    assert {:error, :ingestion_unavailable} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn _ -> {:ok, history(["message-1", "blocked"])} end)
             )

    assert {:ok, %Checkpoint{cursor: "100"}} = Ingestion.checkpoint(scope, box.id)
    assert {:ok, []} = Ingestion.pending(scope, box)
  end

  test "competing complete snapshots use generation/cursor CAS on independent connections", %{
    scope: scope,
    box: box
  } do
    baseline(scope, box)
    parent = self()

    start = fn tag, ids, cursor ->
      Task.async(fn ->
        Sandbox.unboxed_run(TestRepo, fn ->
          Ingestion.catch_up(
            scope,
            box,
            gmail(fn "100" ->
              send(parent, {tag, self()})

              receive do
                :continue -> {:ok, history(ids, cursor)}
              after
                5000 -> raise "test timeout"
              end
            end)
          )
        end)
      end)
    end

    older = start.(:older, ["message-1"], "101")
    newer = start.(:newer, ["message-1", "message-2"], "102")
    assert_receive {:older, older_pid}
    assert_receive {:newer, newer_pid}
    send(newer_pid, :continue)
    assert {:ok, %{cursor: "102"}} = Task.await(newer)
    send(older_pid, :continue)
    assert {:error, :cursor_changed} = Task.await(older)
    assert {:ok, pending} = Ingestion.pending(scope, box)
    assert Enum.map(pending, & &1.message_id) == ["message-1", "message-2"]
  end

  test "ack happens after commit; crash after recording safely redelivers", %{
    scope: scope,
    box: box
  } do
    baseline(scope, box)
    router = fn "owner@acme.com" -> {:ok, scope, box} end

    ack = fn _ ->
      task =
        Task.async(fn ->
          Sandbox.unboxed_run(TestRepo, fn -> Ingestion.checkpoint(scope, box.id) end)
        end)

      assert {:ok, %Checkpoint{requested_id: "102"}} = Task.await(task)
      raise "SYNTHETIC_ACK_CRASH"
    end

    assert {:ok, %{recorded: 1, acknowledged: 0, failed: 1}} =
             NotificationWorker.poll_once({PubSub, [deliveries: [delivery()], ack: ack]}, router)

    assert {:ok, %{recorded: 1, acknowledged: 1, failed: 0}} =
             NotificationWorker.poll_once(
               {PubSub, [deliveries: [delivery()], ack: fn _ -> :ok end]},
               router
             )

    assert {:ok, %Checkpoint{cursor: "100", requested_id: "102"}} =
             Ingestion.checkpoint(scope, box.id)
  end

  test "routing, uninitialized state or failed signal writes never acknowledge", %{
    scope: scope,
    box: box
  } do
    parent = self()

    config = [
      deliveries: [delivery()],
      ack: fn _ ->
        send(parent, :ack)
        :ok
      end
    ]

    for router <- [
          fn _ -> {:error, :unknown_inbox} end,
          fn _ -> {:ok, scope, %{box | address: "other@acme.com"}} end,
          fn _ -> {:ok, scope, box} end
        ] do
      assert {:ok, %{recorded: 0, acknowledged: 0, failed: 1}} =
               NotificationWorker.poll_once({PubSub, config}, router)
    end

    refute_received :ack
  end

  test "failed signal transaction leaves the delivery unacknowledged", %{scope: scope, box: box} do
    baseline(scope, box)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      ~s|ALTER TABLE "#{scope.prefix}".gmail_ingestion ADD CONSTRAINT reject_signal CHECK (requested_id IS NULL)|,
      [],
      log: false
    )

    owner = self()

    assert {:ok, %{recorded: 0, acknowledged: 0, failed: 1}} =
             NotificationWorker.poll_once(
               {PubSub,
                [
                  deliveries: [delivery()],
                  ack: fn _ ->
                    send(owner, :ack)
                    :ok
                  end
                ]},
               fn _ -> {:ok, scope, box} end
             )

    refute_received :ack

    assert {:ok, %Checkpoint{requested_id: nil, cursor: "100"}} =
             Ingestion.checkpoint(scope, box.id)
  end

  test "an outer host transaction cannot acknowledge an uncommitted signal", %{
    scope: scope,
    box: box
  } do
    baseline(scope, box)
    owner = self()

    config = [
      deliveries: [delivery()],
      ack: fn _ ->
        send(owner, :ack)
        :ok
      end
    ]

    assert {:ok, :checked} =
             TestRepo.transaction(fn ->
               assert {:error, :outer_transaction} = Ingestion.record_signal(scope, box, "102")

               assert {:ok, %{recorded: 0, acknowledged: 0, failed: 1}} =
                        NotificationWorker.poll_once({PubSub, config}, fn _ ->
                          {:ok, scope, box}
                        end)

               :checked
             end)

    refute_received :ack
    assert {:ok, %Checkpoint{requested_id: nil}} = Ingestion.checkpoint(scope, box.id)
  end

  test "generated Pub/Sub SDK and committed signal storage cooperate before exact acknowledgement",
       %{scope: scope, box: box} do
    baseline(scope, box)

    {:ok, config} =
      EmailJanitor.Google.PubSub.Config.new(
        "projects/emailjanitor-test/subscriptions/mailbox",
        fn -> {:ok, Content.new("SERVICE_TOKEN_SENTINEL")} end,
        adapter: Tesla.Mock
      )

    Tesla.Mock.mock(fn env ->
      assert {"authorization", "Bearer SERVICE_TOKEN_SENTINEL"} in env.headers

      if String.ends_with?(env.url, ":pull") do
        Tesla.Mock.json(%{
          "receivedMessages" => [
            %{
              "ackId" => "ACK_SENTINEL",
              "message" => %{
                "messageId" => "pubsub-not-gmail-id",
                "data" =>
                  Base.encode64(
                    Jason.encode!(%{"emailAddress" => box.address, "historyId" => "102"})
                  )
              }
            }
          ]
        })
      else
        assert Jason.decode!(env.body) == %{"ackIds" => ["ACK_SENTINEL"]}

        task =
          Task.async(fn ->
            Sandbox.unboxed_run(TestRepo, fn -> Ingestion.checkpoint(scope, box.id) end)
          end)

        assert {:ok, %Checkpoint{requested_id: "102", cursor: "100"}} = Task.await(task)
        Tesla.Mock.json(%{})
      end
    end)

    assert {:ok, %{recorded: 1, acknowledged: 1, failed: 0}} =
             NotificationWorker.poll_once({EmailJanitor.Google.PubSub, config}, fn _ ->
               {:ok, scope, box}
             end)

    assert {:ok, []} = Ingestion.pending(scope, box)
  end

  test "reconnect fences an in-flight history snapshot and stale watch renewal", %{
    scope: scope,
    box: box
  } do
    first = baseline(scope, box)

    assert {:error, :cursor_changed} =
             Ingestion.catch_up(
               scope,
               box,
               gmail(fn "100" ->
                 assert {:ok, _} = Ingestion.reconnect(scope, box, first.generation, watch("300"))
                 {:ok, history(["message-1"], "102")}
               end)
             )

    assert {:ok, current} = Ingestion.checkpoint(scope, box.id)
    assert current.cursor == "300"
    assert {:ok, []} = Ingestion.pending(scope, box)

    assert {:error, :generation_changed} =
             Ingestion.renew_watch(
               scope,
               box,
               "topic",
               {Gmail,
                [
                  renew: fn _ ->
                    assert {:ok, _} =
                             Ingestion.reconnect(scope, box, current.generation, watch("500"))

                    {:ok, watch("999")}
                  end
                ]}
             )

    assert {:ok, %Checkpoint{cursor: "500", baseline_id: "500"}} =
             Ingestion.checkpoint(scope, box.id)
  end

  test "old INBOX mail in a thread is preserved alongside a postbaseline arrival", %{
    scope: scope,
    box: box
  } do
    checkpoint = baseline(scope, box)

    assert {:ok, _} =
             Ingestion.catch_up(scope, box, gmail(fn _ -> {:ok, history(["new-message"])} end))

    messages = [Fixtures.message(id: "old-message"), Fixtures.message(id: "new-message")]

    adapter =
      {Gmail,
       [
         thread_id: fn "new-message" -> {:ok, "thread-1"} end,
         thread: fn "thread-1" -> {:ok, messages} end
       ]}

    assert {:skip, :prebaseline_inbox} =
             Ingestion.eligible_thread(scope, box, checkpoint.generation, "new-message", adapter)

    assert {:ok, [%Arrival{message_id: "new-message"}]} = Ingestion.pending(scope, box)
  end

  test "eligible proof restricts proposal IDs and is invalidated on reconnect", %{
    scope: scope,
    box: box
  } do
    checkpoint = baseline(scope, box)

    assert {:ok, _} =
             Ingestion.catch_up(scope, box, gmail(fn _ -> {:ok, history(["message-1"])} end))

    adapter =
      {Gmail,
       [
         thread_id: fn _ -> {:ok, "thread-1"} end,
         thread: fn _ -> {:ok, [Fixtures.message(body: "PRIVATE_BODY_SENTINEL")]} end
       ]}

    assert {:ok, eligible} =
             Ingestion.eligible_thread(scope, box, checkpoint.generation, "message-1", adapter)

    assert :ok = Ingestion.authorize_proposal(scope, box, eligible, proposal(["message-1"]))

    for ids <- [[], ["old-message"], ["message-1", "old-message"], ["message-1", "message-1"]] do
      assert {:error, :ineligible_proposal} =
               Ingestion.authorize_proposal(scope, box, eligible, proposal(ids))
    end

    assert {:ok, :ok} = Ingestion.mark_processed(scope, box, checkpoint.generation, ["message-1"])
    assert {:ok, []} = Ingestion.pending(scope, box)
    refute inspect(eligible) =~ "PRIVATE_BODY_SENTINEL"
    assert {:ok, _} = Ingestion.reconnect(scope, box, checkpoint.generation, watch("300"))

    assert {:error, :ineligible_proposal} =
             Ingestion.authorize_proposal(scope, box, eligible, proposal(["message-1"]))

    assert {:error, :generation_changed} =
             Ingestion.mark_processed(scope, box, checkpoint.generation, ["message-1"])
  end

  test "deleted arrivals and archive-only threads are skipped without fetching more content", %{
    scope: scope,
    box: box
  } do
    checkpoint = baseline(scope, box)

    assert {:ok, _} =
             Ingestion.catch_up(scope, box, gmail(fn _ -> {:ok, history(["message-1"])} end))

    assert {:skip, :deleted_arrival} =
             Ingestion.eligible_thread(
               scope,
               box,
               checkpoint.generation,
               "message-1",
               {Gmail, [thread_id: fn _ -> {:error, :not_found} end]}
             )

    adapter =
      {Gmail,
       [
         thread_id: fn _ -> {:ok, "thread-1"} end,
         thread: fn _ -> {:ok, [Fixtures.message(labels: ["UNREAD"])]} end
       ]}

    assert {:skip, :not_in_inbox} =
             Ingestion.eligible_thread(scope, box, checkpoint.generation, "message-1", adapter)
  end

  test "same inbox ID in another storage scope has independent eligibility", %{
    scope: scope,
    box: box
  } do
    first = baseline(scope, box)

    assert {:ok, _} =
             Ingestion.catch_up(scope, box, gmail(fn _ -> {:ok, history(["message-1"])} end))

    other_prefix = scope.prefix <> "_b"
    {:ok, other} = Scope.new(TestRepo, other_prefix)
    {:ok, installer} = Scope.new(MigrationRepo, other_prefix)
    assert :ok = Ingestion.install(installer)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(MigrationRepo, ~s(DROP SCHEMA "#{other_prefix}" CASCADE), [],
        log: false
      )
    end)

    assert {:ok, _} = Store.add_inbox(other, box)
    second = baseline(other, box, "300")
    refute first.generation == second.generation
    assert {:ok, []} = Ingestion.pending(other, box)

    assert {:error, :eligibility_unavailable} =
             Ingestion.eligible_thread(other, box, first.generation, "message-1", {Gmail, []})

    assert {:ok, [%Arrival{message_id: "message-1"}]} = Ingestion.pending(scope, box)
  end
end
