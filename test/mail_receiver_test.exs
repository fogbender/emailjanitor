defmodule EmailJanitor.MailReceiverTest.Repo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.MailReceiverTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Inbox, Store}
  alias EmailJanitor.Mail.{Feedback, Incoming, Receiver, Spool}
  alias EmailJanitor.Mail.Feedback.{Config, Record, Route}
  alias EmailJanitor.MailReceiverTest.Repo
  alias EmailJanitor.MailFixture, as: F

  setup_all do
    start_supervised!(
      {Repo,
       socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
       database: "emailjanitor_test",
       username: System.fetch_env!("USER"),
       port: 5432,
       pool_size: 10,
       log: false}
    )

    :ok
  end

  setup do
    prefix = "ej_receiver_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    {:ok, scope} = Store.Scope.new(Repo, prefix)
    Store.install(scope)
    Feedback.install(scope)
    {:ok, transport} = Inbox.new("transport", "janitor@janitor.example.com")
    {:ok, sender} = Inbox.new("owner", "owner@example.com")
    for inbox <- [transport, sender], do: Store.add_inbox(scope, inbox)
    on_exit(fn -> Repo.query!(~s(DROP SCHEMA "#{prefix}" CASCADE), [], log: false) end)
    %{scope: scope, transport: transport, sender: sender}
  end

  defp config(ctx, mail) do
    {:ok, config} =
      Config.new(
        transport_scope: ctx.scope,
        transport_inbox: ctx.transport,
        mail: mail,
        parser_executable: System.find_executable("emailjanitor-reply-parser"),
        route: fn envelope ->
          if envelope.from == ctx.sender.address,
            do: {:ok, %Route{key: "owner_epoch_1", inbox_id: ctx.sender.id}},
            else: :unknown
        end,
        resolve: fn _ -> flunk("intake/raw disposal must not fetch Sent or run a workflow") end
      )

    config
  end

  defp notification(id) do
    {_receipt, json} = F.receipt(F.config(fn _ -> flunk("unused") end), id)
    Jason.encode!(json)
  end

  defp poll_response(conn, id) do
    Plug.Conn.send_resp(
      conn,
      200,
      "<ReceiveMessageResponse><ReceiveMessageResult><Message><MessageId>q1</MessageId><ReceiptHandle>handle1</ReceiptHandle><Body>#{notification(id)}</Body><MD5OfBody>x</MD5OfBody></Message></ReceiveMessageResult></ReceiveMessageResponse>"
    )
  end

  test "acknowledgement follows durable acceptance and a fresh processor recovers then purges before Sent lookup",
       ctx do
    observer = self()

    raw =
      "From: owner@example.com\r\nTo: janitor@janitor.example.com\r\nSubject: Cleanup\r\nMessage-ID: <intake@example.com>\r\n\r\nPRIVATE_SMTP_COMMAND_BODY"

    mail =
      F.config(fn conn ->
        case conn.method do
          "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            case URI.decode_query(body)["Action"] do
              "ReceiveMessage" ->
                poll_response(conn, "ses-intake")

              "DeleteMessage" ->
                assert %Incoming{state: :pending} = Spool.get(ctx.scope, "ses-intake")
                send(observer, :acked_durable)
                Plug.Conn.send_resp(conn, 200, "<DeleteMessageResponse/>")
            end

          "GET" ->
            send(observer, :raw_read)
            Plug.Conn.send_resp(conn, 200, raw)

          "DELETE" ->
            assert %Record{source_ses_id: "ses-intake"} =
                     Repo.one(Record, prefix: ctx.scope.prefix)

            send(observer, :purged_after_metadata)
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

    config = config(ctx, mail)
    assert {:next, nil, 1000} = Receiver.receive_once(config)
    assert_received :acked_durable
    refute_received :raw_read
    # No receiver process state or queue redelivery is needed after the ACK.
    assert {:next, nil, 0} = Receiver.process_once(config)
    assert_received :raw_read
    assert_received :purged_after_metadata
    assert %Incoming{state: :deleted} = Spool.get(ctx.scope, "ses-intake")
    row = Repo.one!(Record, prefix: ctx.scope.prefix)
    assert :binary.match(:erlang.term_to_binary(row), "PRIVATE_SMTP_COMMAND_BODY") == :nomatch
    assert Repo.aggregate(EmailJanitor.Mail.Outgoing, :count, prefix: ctx.scope.prefix) == 0
    assert {:next, nil, 1000} = Receiver.process_once(config)
  end

  test "an unregistered transport cannot acknowledge a delivery", ctx do
    observer = self()

    mail =
      F.config(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        action = URI.decode_query(body)["Action"]
        send(observer, {:sqs, action})
        assert action == "ReceiveMessage"
        poll_response(conn, "ses-unaccepted")
      end)

    config = config(ctx, mail)
    config = %{config | transport_inbox: %{ctx.transport | id: "missing-transport"}}
    assert {:next, nil, 1000} = Receiver.receive_once(config)
    assert_received {:sqs, "ReceiveMessage"}
    refute_received {:sqs, "DeleteMessage"}
    assert Repo.aggregate(Incoming, :count, prefix: ctx.scope.prefix) == 0
  end

  test "expired input is deleted independently without reading or parsing its body", ctx do
    observer = self()

    mail =
      F.config(fn conn ->
        assert conn.method == "DELETE"
        send(observer, :expired_deleted)
        Plug.Conn.send_resp(conn, 204, "")
      end)

    {receipt, _} = F.receipt(mail, "ses-expired", DateTime.add(DateTime.utc_now(), -3601))
    {:ok, _} = Spool.accept(ctx.scope, ctx.transport.id, receipt)
    config = config(ctx, mail)
    assert {:next, nil, 1000} = Receiver.process_once(config)
    refute_received :expired_deleted
    assert {:next, nil, 60_000} = Receiver.sweep(config, nil)
    assert_received :expired_deleted
    assert %Incoming{state: :deleted, outcome: :expired} = Spool.get(ctx.scope, receipt.id)
    assert Repo.aggregate(Record, :count, prefix: ctx.scope.prefix) == 0
  end

  test "orphan cleanup drains continuations after a failed page and never fetches raw bodies",
       ctx do
    observer = self()
    past = DateTime.add(DateTime.utc_now(), -7200) |> DateTime.to_iso8601()

    mail =
      F.config(fn conn ->
        case conn.method do
          "GET" ->
            assert conn.request_path == "/janitor-spool/"
            conn = Plug.Conn.fetch_query_params(conn)

            case conn.query_params["marker"] do
              nil ->
                Plug.Conn.send_resp(
                  conn,
                  200,
                  "<ListBucketResult><IsTruncated>true</IsTruncated><NextMarker>incoming/later</NextMarker><Contents><Key>incoming/nested/poison</Key><LastModified>#{past}</LastModified><Size>1</Size></Contents></ListBucketResult>"
                )

              "incoming/later" ->
                Plug.Conn.send_resp(
                  conn,
                  200,
                  "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>incoming/tail</Key><LastModified>#{past}</LastModified><Size>1</Size></Contents></ListBucketResult>"
                )
            end

          "DELETE" ->
            send(observer, {:deleted, conn.request_path})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

    config = config(ctx, mail)
    assert {:next, "incoming/later", 0} = Receiver.sweep_orphans(config, nil)
    assert {:next, nil, 60_000} = Receiver.sweep_orphans(config, "incoming/later")
    assert_received {:deleted, "/janitor-spool/incoming/tail"}
    assert map_size(Receiver.tasks(config)) == 6
    assert Enum.all?(Receiver.tasks(config), fn {_, task} -> is_function(task.run, 1) end)
    assert {:next, nil, 60_000} = Receiver.purge_feedback(config)
    refute inspect(config) =~ "PRIVATE_SMTP_COMMAND_BODY"
  end
end
