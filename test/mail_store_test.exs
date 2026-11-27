defmodule EmailJanitor.MailStoreTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Store, TestRepo}
  alias EmailJanitor.Mail.{Incoming, Outbox, Spool}
  alias EmailJanitor.MailFixture, as: F
  alias EmailJanitor.Store.Scope

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    {:ok, other} = Scope.new(TestRepo, "ej_test_b")
    inbox = F.inbox()
    {:ok, _} = Store.add_inbox(scope, inbox)
    {:ok, _} = Store.add_inbox(other, inbox)
    %{scope: scope, other: other, inbox: inbox}
  end

  defp intent(scope, inbox) do
    Outbox.enqueue(scope, inbox.id, :digest, [Ecto.UUID.generate()], Ecto.UUID.generate())
  end

  test "intent deduplication and schema isolation; body never enters SQL", ctx do
    dedupe = Ecto.UUID.generate()
    refs = [Ecto.UUID.generate()]
    {:ok, row} = Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, refs, dedupe)
    assert {:ok, %{id: id}} = Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, refs, dedupe)
    assert id == row.id
    assert Outbox.get(ctx.other, id) == nil

    assert {:error, :invalid_outbox_intent} =
             Outbox.enqueue(ctx.scope, ctx.inbox.id, :assistant, ["PRIVATE-BODY"], dedupe)

    assert {:error, :invalid_outbox_intent} =
             Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, refs, "PRIVATE-BODY")

    columns =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name IN ('mail_outbox','mail_spool')",
        [ctx.scope.prefix]
      ).rows
      |> List.flatten()

    refute Enum.any?(columns, &(&1 in ["body", "content", "raw", "message", "reply", "payload"]))
  end

  test "successful delivery can be replayed without sending again", ctx do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, :sent)
        F.ses_response(conn)
      end)

    {:ok, row} = intent(ctx.scope, ctx.inbox)
    authorize = fn _ -> {:ok, ctx.inbox} end

    render = fn metadata ->
      assert metadata.reference_ids == row.reference_ids
      {:ok, F.message()}
    end

    assert :ok = Outbox.deliver(ctx.scope, row.id, config, authorize, render)
    assert :ok = Outbox.deliver(ctx.scope, row.id, config, authorize, render)
    assert_received :sent
    refute_received :sent
    assert Outbox.get(ctx.scope, row.id).state == :sent
  end

  test "disconnected and cross-inbox authorizers cannot send", ctx do
    config = F.config(fn _ -> flunk("unauthorized network") end)
    {:ok, row} = intent(ctx.scope, ctx.inbox)

    assert {:error, _} =
             Outbox.deliver(
               ctx.scope,
               row.id,
               config,
               fn _ -> {:error, :disconnected} end,
               fn _ -> {:ok, F.message()} end
             )

    assert {:error, _} =
             Outbox.deliver(
               ctx.scope,
               row.id,
               config,
               fn _ -> {:ok, %{ctx.inbox | address: "attacker@example.com"}} end,
               fn _ -> {:ok, F.message()} end
             )

    assert Outbox.get(ctx.scope, row.id).state == :pending
  end

  test "crash after SES dispatch leaves a durable fence and never resends", ctx do
    config = F.config(fn _ -> Process.exit(self(), :kill) end)
    {:ok, row} = intent(ctx.scope, ctx.inbox)
    authorize = fn _ -> {:ok, ctx.inbox} end

    assert {:error, :executor_unavailable} =
             Outbox.deliver(ctx.scope, row.id, config, authorize, fn _ -> {:ok, F.message()} end)

    assert Outbox.get(ctx.scope, row.id).state == :dispatching

    assert {:error, :unresolved_delivery} =
             Outbox.deliver(ctx.scope, row.id, config, authorize, fn _ ->
               flunk("rendered replay")
             end)
  end

  test "render failure before fence is retryable and sanitized", ctx do
    config = F.config(&F.ses_response/1)
    {:ok, row} = intent(ctx.scope, ctx.inbox)

    log =
      capture_log(fn ->
        assert {:error, :executor_unavailable} =
                 Outbox.deliver(ctx.scope, row.id, config, fn _ -> {:ok, ctx.inbox} end, fn _ ->
                   raise "PRIVATE-MAIL-SENTINEL"
                 end)
      end)

    refute log =~ "PRIVATE-MAIL-SENTINEL"
    assert Outbox.get(ctx.scope, row.id).state == :pending

    assert :ok =
             Outbox.deliver(ctx.scope, row.id, config, fn _ -> {:ok, ctx.inbox} end, fn _ ->
               {:ok, F.message()}
             end)
  end

  test "spool keeps trusted metadata only; successful processing deletes and does not repeat handler",
       ctx do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, {:request, conn.method})

        Plug.Conn.send_resp(
          conn,
          200,
          if(conn.method == "GET", do: "PRIVATE-INCOMING-BODY", else: "")
        )
      end)

    {receipt, _} = F.receipt(config)
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)
    assert {:ok, %{id: id}} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)
    assert id == row.id

    handler = fn metadata, content ->
      assert metadata.id == receipt.id
      assert metadata.verdicts == receipt.verdicts
      assert Content.read(content) == "PRIVATE-INCOMING-BODY"
      send(parent, :handled)
      {:ok, Ecto.UUID.generate()}
    end

    assert :ok = Spool.process(ctx.scope, row.id, config, handler)
    assert :ok = Spool.process(ctx.scope, row.id, config, handler)
    assert_received :handled
    refute_received :handled
    assert_received {:request, "GET"}
    assert_received {:request, "DELETE"}
    refute_received {:request, _}
    assert TestRepo.get!(Incoming, row.id, prefix: ctx.scope.prefix).state == :deleted
  end

  test "parser/authentication failure is purged at TTL without fetching again", ctx do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, {:method, conn.method})
        Plug.Conn.send_resp(conn, 200, "PRIVATE-INCOMING-BODY")
      end)

    {receipt, _} = F.receipt(config)
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)

    log =
      capture_log(fn ->
        assert {:error, :executor_unavailable} =
                 Spool.process(ctx.scope, row.id, config, fn _, _ ->
                   raise "PRIVATE-INCOMING-BODY"
                 end)
      end)

    refute log =~ "PRIVATE-INCOMING-BODY"
    assert_received {:method, "GET"}

    TestRepo.update_all(
      from(i in Incoming, where: i.id == ^row.id),
      [set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: ctx.scope.prefix
    )

    assert :ok = Spool.sweep(ctx.scope, config)
    assert_received {:method, "DELETE"}
    refute_received {:method, "GET"}
    saved = TestRepo.get!(Incoming, row.id, prefix: ctx.scope.prefix)
    assert saved.state == :deleted
    assert saved.outcome == :expired
    assert saved.workflow_id == nil
  end

  test "expired unroutable objects are deleted without reading MIME", _ctx do
    parent = self()
    past = DateTime.add(DateTime.utc_now(), -3700) |> DateTime.to_iso8601()

    config =
      F.config(fn conn ->
        send(parent, {conn.method, conn.request_path})

        case conn.method do
          "GET" ->
            Plug.Conn.send_resp(
              conn,
              200,
              "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>incoming/unroutable</Key><LastModified>#{past}</LastModified><Size>10</Size></Contents></ListBucketResult>"
            )

          "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

    assert {:ok, nil} = Spool.sweep_orphans(config)
    assert_received {"GET", "/janitor-spool/"}
    assert_received {"DELETE", "/janitor-spool/incoming/unroutable"}
    refute_received {"GET", _}
  end

  test "outer transactions cannot dispatch or accept uncommitted references", ctx do
    {:ok, row} = intent(ctx.scope, ctx.inbox)
    config = F.config(fn _ -> flunk("network inside transaction") end)

    assert {:ok, :ok} =
             TestRepo.transaction(fn ->
               assert {:error, :outer_transaction} =
                        Outbox.deliver(
                          ctx.scope,
                          row.id,
                          config,
                          fn _ -> {:ok, ctx.inbox} end,
                          fn _ -> {:ok, F.message()} end
                        )

               assert {:error, :outer_transaction} =
                        Spool.process(ctx.scope, "ses-123", config, fn _, _ -> :ignored end)

               :ok
             end)

    assert Outbox.get(ctx.scope, row.id).state == :pending
  end

  test "two concurrent workers can cross the send fence only once", ctx do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, :sent)
        F.ses_response(conn)
      end)

    {:ok, row} = intent(ctx.scope, ctx.inbox)

    workers =
      for _ <- 1..2 do
        Task.async(fn ->
          Outbox.deliver(ctx.scope, row.id, config, fn _ -> {:ok, ctx.inbox} end, fn _ ->
            {:ok, F.message()}
          end)
        end)
      end

    results = Enum.map(workers, &Task.await/1)
    assert :ok in results
    assert_received :sent
    refute_received :sent
  end

  test "intent can commit atomically with host digest listing and rejects dedupe drift", ctx do
    dedupe = Ecto.UUID.generate()
    refs = [Ecto.UUID.generate()]

    assert {:error, :host_workflow_rollback} =
             TestRepo.transaction(fn ->
               {:ok, row} = Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, refs, dedupe)
               assert Outbox.get(ctx.scope, row.id)
               TestRepo.rollback(:host_workflow_rollback)
             end)

    assert {:ok, row} = Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, refs, dedupe)
    assert row.state == :pending

    assert {:error, :outbox_reference_conflict} =
             Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, [Ecto.UUID.generate()], dedupe)
  end

  test "failed object deletion retries purge without repeating a completed workflow", ctx do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, {:request, conn.method})

        Plug.Conn.send_resp(
          conn,
          if(conn.method == "DELETE", do: 503, else: 200),
          "PRIVATE-INCOMING-BODY"
        )
      end)

    {receipt, _} = F.receipt(config, "ses-delete-failure")
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)

    assert {:error, :mail_unavailable} =
             Spool.process(ctx.scope, row.id, config, fn _, _ ->
               send(parent, :handled)
               {:ok, Ecto.UUID.generate()}
             end)

    assert TestRepo.get!(Incoming, row.id, prefix: ctx.scope.prefix).state == :purge
    assert_received :handled
    assert_received {:request, "GET"}
    assert_received {:request, "DELETE"}
    refute_received {:request, _}

    working =
      F.config(fn conn ->
        send(parent, {:retry, conn.method})
        Plug.Conn.send_resp(conn, 204, "")
      end)

    assert :ok =
             Spool.process(ctx.scope, row.id, working, fn _, _ -> flunk("workflow ran twice") end)

    assert_received {:retry, "DELETE"}
    refute_received {:retry, "GET"}
    refute_received :handled
  end

  test "killed inbound handler recovers with its stable receipt identity after bounded lease",
       ctx do
    config = F.config(fn conn -> Plug.Conn.send_resp(conn, 200, "PRIVATE-INCOMING-BODY") end)
    {receipt, _} = F.receipt(config, "ses-handler-crash")
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)

    assert {:error, :executor_unavailable} =
             Spool.process(ctx.scope, row.id, config, fn _, _ -> Process.exit(self(), :kill) end)

    assert TestRepo.get!(Incoming, row.id, prefix: ctx.scope.prefix).state == :processing

    TestRepo.update_all(
      from(i in Incoming, where: i.id == ^row.id),
      [set: [lease_until: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: ctx.scope.prefix
    )

    assert :ok =
             Spool.process(ctx.scope, row.id, config, fn metadata, _ ->
               assert metadata.id == receipt.id
               :rejected
             end)

    assert TestRepo.get!(Incoming, row.id, prefix: ctx.scope.prefix).outcome == :rejected
  end

  test "uppercase reference UUIDs are normalized before first insert and dedupe", ctx do
    uuid = Ecto.UUID.generate()
    dedupe = Ecto.UUID.generate()

    assert {:ok, row} =
             Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, [String.upcase(uuid)], dedupe)

    assert row.reference_ids == [uuid]
    assert {:ok, %{id: id}} = Outbox.enqueue(ctx.scope, ctx.inbox.id, :digest, [uuid], dedupe)
    assert id == row.id
  end

  test "expired purge retains a completed workflow outcome, then metadata is retired", ctx do
    failing =
      F.config(fn conn ->
        Plug.Conn.send_resp(conn, if(conn.method == "DELETE", do: 503, else: 200), "PRIVATE-BODY")
      end)

    {receipt, _} = F.receipt(failing, "ses-retirement")
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)
    workflow = Ecto.UUID.generate()

    assert {:error, :mail_unavailable} =
             Spool.process(ctx.scope, row.id, failing, fn _, _ -> {:ok, workflow} end)

    TestRepo.update_all(
      from(i in Incoming, where: i.id == ^row.id),
      [set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: ctx.scope.prefix
    )

    working = F.config(fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert :ok = Spool.sweep(ctx.scope, working)
    saved = Spool.get(ctx.scope, row.id)
    assert saved.state == :deleted
    assert saved.outcome == :processed
    assert saved.workflow_id == workflow

    TestRepo.update_all(
      from(i in Incoming, where: i.id == ^row.id),
      [set: [expires_at: DateTime.add(DateTime.utc_now(), -5401)]],
      prefix: ctx.scope.prefix
    )

    assert :ok = Spool.sweep(ctx.scope, working)
    assert Spool.get(ctx.scope, row.id) == nil
  end

  test "oversized forward records its terminal outcome and is purged immediately", ctx do
    parent = self()

    config = %{
      F.config(fn _ -> flunk("GET attempted") end)
      | test_plug: fn conn ->
          send(parent, {:method, conn.method})

          case conn.method do
            "HEAD" ->
              conn
              |> Plug.Conn.put_resp_header("content-length", "1048577")
              |> Plug.Conn.send_resp(200, "")

            "DELETE" ->
              Plug.Conn.send_resp(conn, 204, "")
          end
        end
    }

    {receipt, _} = F.receipt(config, "ses-too-large")
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)

    assert {:error, :mail_too_large} =
             Spool.process(ctx.scope, row.id, config, fn _, _ ->
               flunk("handler saw oversized content")
             end)

    assert_received {:method, "HEAD"}
    assert_received {:method, "DELETE"}
    refute_received {:method, "GET"}
    assert %{state: :deleted, outcome: :too_large} = Spool.get(ctx.scope, row.id)

    assert {:error, :mail_too_large} =
             Spool.process(ctx.scope, row.id, config, fn _, _ -> flunk("terminal retry") end)

    refute_received {:method, _}
  end

  test "one poisoned orphan cannot hide the continuation marker for later pages", _ctx do
    parent = self()
    past = DateTime.add(DateTime.utc_now(), -3700) |> DateTime.to_iso8601()

    config =
      F.config(fn conn ->
        send(parent, {conn.method, conn.request_path, conn.query_string})

        case {conn.method, URI.decode_query(conn.query_string)["marker"]} do
          {"GET", nil} ->
            Plug.Conn.send_resp(
              conn,
              200,
              "<ListBucketResult><IsTruncated>true</IsTruncated><NextMarker>incoming/later</NextMarker><Contents><Key>incoming/nested/poison</Key><LastModified>#{past}</LastModified><Size>1</Size></Contents></ListBucketResult>"
            )

          {"GET", "incoming/later"} ->
            Plug.Conn.send_resp(
              conn,
              200,
              "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>incoming/tail</Key><LastModified>#{past}</LastModified><Size>1</Size></Contents></ListBucketResult>"
            )

          {"DELETE", nil} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

    assert {:error, :spool_cleanup_failed, "incoming/later"} = Spool.sweep_orphans(config)
    assert {:ok, nil} = Spool.sweep_orphans(config, "incoming/later")
    assert_received {"GET", "/janitor-spool/", _}
    assert_received {"GET", "/janitor-spool/", _}
    assert_received {"DELETE", "/janitor-spool/incoming/tail", _}
    refute_received {"GET", _, _}
  end

  test "window exhausted after the fence is proven unsent and safely retried", ctx do
    Ecto.Adapters.SQL.query!(
      TestRepo,
      "CREATE TABLE #{ctx.scope.prefix}.dispatch_probe (id uuid)",
      [],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      TestRepo,
      """
      CREATE FUNCTION #{ctx.scope.prefix}.delay_dispatch() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.state = 'dispatching' AND OLD.state = 'pending' THEN
          INSERT INTO #{ctx.scope.prefix}.dispatch_probe(id) VALUES (NEW.id);
          PERFORM pg_sleep(0.25);
        END IF;
        RETURN NEW;
      END $$
      """,
      [],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "CREATE TRIGGER delay_dispatch BEFORE UPDATE ON #{ctx.scope.prefix}.mail_outbox FOR EACH ROW EXECUTE FUNCTION #{ctx.scope.prefix}.delay_dispatch()",
      [],
      log: false
    )

    parent = self()

    normal =
      F.config(fn conn ->
        send(parent, :sent)
        F.ses_response(conn)
      end)

    resolve = normal.credentials

    short = %{
      normal
      | credentials: fn ->
          Process.put(
            {EmailJanitor.Owner, :execution_deadline},
            System.monotonic_time(:millisecond) + 31_100
          )

          resolve.()
        end
    }

    {:ok, row} = intent(ctx.scope, ctx.inbox)

    assert {:error, :mail_unavailable} =
             Outbox.deliver(ctx.scope, row.id, short, fn _ -> {:ok, ctx.inbox} end, fn _ ->
               {:ok, F.message()}
             end)

    assert TestRepo.aggregate("dispatch_probe", :count, prefix: ctx.scope.prefix) == 1
    assert Outbox.get(ctx.scope, row.id).state == :pending
    refute_received :sent

    assert :ok =
             Outbox.deliver(ctx.scope, row.id, normal, fn _ -> {:ok, ctx.inbox} end, fn _ ->
               {:ok, F.message()}
             end)

    assert_received :sent
    refute_received :sent
  end

  test "deadline deletion preserves the same running handler's eventual outcome", ctx do
    config =
      F.config(fn conn ->
        Plug.Conn.send_resp(
          conn,
          if(conn.method == "DELETE", do: 204, else: 200),
          if(conn.method == "DELETE", do: "", else: "PRIVATE-INCOMING-BODY")
        )
      end)

    {receipt, _} = F.receipt(config, "ses-deadline-handler")
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)
    parent = self()
    workflow = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Spool.process(ctx.scope, row.id, config, fn _, _ ->
          send(parent, {:handler_running, self()})

          receive do
            :finish -> {:ok, workflow}
          after
            5000 -> :rejected
          end
        end)
      end)

    assert_receive {:handler_running, owner}, 5000
    on_exit(fn -> send(owner, :finish) end)

    TestRepo.update_all(
      from(i in Incoming, where: i.id == ^row.id),
      [set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: ctx.scope.prefix
    )

    assert :ok = Spool.sweep(ctx.scope, config)
    assert %{state: :deleted, outcome: :expired} = Spool.get(ctx.scope, row.id)
    send(owner, :finish)
    assert :ok = Task.await(task, 5000)

    assert %{state: :deleted, outcome: :processed, workflow_id: ^workflow} =
             Spool.get(ctx.scope, row.id)
  end

  test "size response finishing after deadline deletion keeps its typed replay outcome", ctx do
    parent = self()

    config = %{
      F.config(fn _ -> flunk("GET attempted") end)
      | test_plug: fn conn ->
          case conn.method do
            "HEAD" ->
              send(parent, {:head_running, self()})

              receive do
                :finish -> :ok
              after
                5000 -> :ok
              end

              conn
              |> Plug.Conn.put_resp_header("content-length", "1048577")
              |> Plug.Conn.send_resp(200, "")

            "DELETE" ->
              Plug.Conn.send_resp(conn, 204, "")
          end
        end
    }

    {receipt, _} = F.receipt(config, "ses-deadline-size")
    {:ok, row} = Spool.accept(ctx.scope, ctx.inbox.id, receipt)

    task =
      Task.async(fn ->
        Spool.process(ctx.scope, row.id, config, fn _, _ -> flunk("oversized handler") end)
      end)

    assert_receive {:head_running, owner}, 5000
    on_exit(fn -> send(owner, :finish) end)

    TestRepo.update_all(
      from(i in Incoming, where: i.id == ^row.id),
      [set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: ctx.scope.prefix
    )

    assert :ok = Spool.sweep(ctx.scope, config)
    assert %{state: :deleted, outcome: :expired} = Spool.get(ctx.scope, row.id)
    send(owner, :finish)
    assert {:error, :mail_too_large} = Task.await(task, 5000)
    assert %{state: :deleted, outcome: :too_large} = Spool.get(ctx.scope, row.id)

    assert {:error, :mail_too_large} =
             Spool.process(ctx.scope, row.id, config, fn _, _ ->
               flunk("replayed size handler")
             end)
  end

  test "self-mail exemption binds exact current headers and successful scoped sender/recipient evidence",
       ctx do
    config = F.config(&F.ses_response/1)
    {:ok, row} = intent(ctx.scope, ctx.inbox)

    headers = [
      {"From", "Janitor <#{config.sender}>"},
      {"Message-ID", "<ses-outgoing-123@EMAIL.AMAZONSES.COM>"}
    ]

    assert {:ok, false} = Outbox.self_delivery?(ctx.scope, ctx.inbox.id, config.sender, headers)

    assert :ok =
             Outbox.deliver(ctx.scope, row.id, config, fn _ -> {:ok, ctx.inbox} end, fn _ ->
               {:ok, F.message()}
             end)

    assert %{sender: sender, recipient: recipient} = Outbox.get(ctx.scope, row.id)
    assert sender == config.sender and recipient == ctx.inbox.address
    assert {:ok, true} = Outbox.self_delivery?(ctx.scope, ctx.inbox.id, config.sender, headers)
    assert {:ok, false} = Outbox.self_delivery?(ctx.other, ctx.inbox.id, config.sender, headers)
    assert {:ok, false} = Outbox.self_delivery?(ctx.scope, "other-inbox", config.sender, headers)

    assert {:ok, false} =
             Outbox.self_delivery?(ctx.scope, ctx.inbox.id, "other@janitor.example.com", headers)

    for bad <- [
          [{"from", config.sender}, {"message-id", "<unknown@email.amazonses.com>"}],
          [{"from", config.sender}, {"message-id", "<ses-outgoing-123@attacker.example>"}],
          [
            {"from", config.sender},
            {"message-id", "<ses-outgoing-123@email.amazonses.com.attacker.example>"}
          ],
          [{"from", config.sender}, {"references", "<ses-outgoing-123@email.amazonses.com>"}],
          headers ++ [{"message-id", "<ses-outgoing-123@email.amazonses.com>"}],
          headers ++ [{"from", "attacker@example.net"}]
        ] do
      assert {:ok, false} = Outbox.self_delivery?(ctx.scope, ctx.inbox.id, config.sender, bad)
    end

    TestRepo.update_all(
      from(o in EmailJanitor.Mail.Outgoing, where: o.id == ^row.id),
      [set: [recipient: "someone@example.net"]],
      prefix: ctx.scope.prefix
    )

    assert {:ok, false} = Outbox.self_delivery?(ctx.scope, ctx.inbox.id, config.sender, headers)
  end

  test "self-mail evidence lookup fails closed on unavailable storage", ctx do
    {:ok, absent} = Scope.new(TestRepo, "ej_absent_self_mail")

    headers = [
      {"from", "janitor@janitor.example.com"},
      {"message-id", "<ses-id@email.amazonses.com>"}
    ]

    assert {:error, :self_mail_unavailable} =
             Outbox.self_delivery?(absent, ctx.inbox.id, "janitor@janitor.example.com", headers)
  end
end
