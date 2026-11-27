defmodule EmailJanitor.MailSDKTest do
  use ExUnit.Case, async: false
  require Logger
  import ExUnit.CaptureLog
  alias EmailJanitor.Content
  alias EmailJanitor.Mail.{Config, HTTP, Message, Receipt, SDK}
  alias EmailJanitor.MailFixture, as: F

  test "SES SDK signs a single bounded request, with a host-selected recipient" do
    parent = self()

    config =
      F.config(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request, conn.host, URI.decode_query(body), conn.req_headers})
        F.ses_response(conn)
      end)

    assert {:ok, prepared} = SDK.prepare(config)
    assert {:ok, "ses-outgoing-123"} = SDK.send(config, prepared, F.inbox(), F.message())
    assert_received {:request, "email.us-east-1.amazonaws.com", params, headers}
    assert params["Action"] == "SendEmail"
    assert params["Destination.ToAddresses.member.1"] == "owner@example.com"
    assert params["Source"] == config.sender
    assert params["Message.Body.Text.Data"] == "PRIVATE-MAIL-SENTINEL"

    assert Enum.any?(headers, fn {name, value} ->
             name == "authorization" and String.contains?(value, "AWS4-HMAC-SHA256")
           end)

    assert inspect(prepared) =~ "REDACTED"
    refute Jason.encode!(prepared) =~ "synthetic-secret"
    refute inspect(F.message()) =~ "PRIVATE-MAIL"
  end

  test "SES server rejection is ambiguous and is not retried" do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, :sent)
        Plug.Conn.send_resp(conn, 503, "PRIVATE-MAIL-SENTINEL")
      end)

    {:ok, prepared} = SDK.prepare(config)

    log =
      capture_log(fn ->
        assert {:error, :unresolved_delivery} = SDK.send(config, prepared, F.inbox(), F.message())
      end)

    assert_received :sent
    refute_received :sent
    refute log =~ "PRIVATE-MAIL-SENTINEL"
  end

  test "HTTP/parser exceptions are sanitized before SDK logging" do
    config = F.config(fn _ -> raise "PRIVATE-MAIL-SENTINEL" end)
    {:ok, prepared} = SDK.prepare(config)

    log =
      capture_log(fn ->
        assert {:error, :unresolved_delivery} = SDK.send(config, prepared, F.inbox(), F.message())
      end)

    refute log =~ "PRIVATE-MAIL-SENTINEL"
  end

  test "unsafe observers fail closed before resolving credentials" do
    parent = self()

    for event <- [
          [:finch, :request, :start],
          [:email_janitor, :private_mail_sdk, :start],
          [:ex_aws, :request, :start]
        ] do
      handler = make_ref()
      :ok = :telemetry.attach(handler, event, fn _, _, _, _ -> :ok end, nil)

      config = %{
        F.config(fn _ -> flunk("network") end)
        | credentials: fn ->
            send(parent, :credentials)
            raise "secret"
          end
      }

      assert {:error, :mail_unavailable} = SDK.prepare(config)
      refute_received :credentials
      :telemetry.detach(handler)
    end
  end

  test "response size cap and XML entity declarations fail closed" do
    for body <- [
          String.duplicate("x", 1_048_577),
          "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>"
        ] do
      assert {:error, _} =
               HTTP.request(:get, "https://s3.us-east-1.amazonaws.com/", "", [],
                 test_plug: fn conn -> Plug.Conn.send_resp(conn, 200, body) end
               )
    end
  end

  test "receipt trusts SES envelope/verdict fields and drops MIME headers" do
    config = F.config(fn _ -> flunk("network") end)
    {receipt, _} = F.receipt(config)
    assert receipt.envelope_from == "owner@example.com"
    assert receipt.key == "incoming/ses-123"
    assert receipt.verdicts["dkimVerdict"] == "PASS"
    refute inspect(receipt) =~ "PRIVATE-HEADER"
    refute inspect(receipt) =~ "attacker@example.net"
  end

  test "wrong provenance, direct SNS content, missing verdicts and S3 object events are rejected" do
    config = F.config(fn _ -> flunk("network") end)
    {_, json} = F.receipt(config)

    bad = [
      Map.put(json, "content", "PRIVATE-MAIL-SENTINEL"),
      put_in(
        json,
        ["receipt", "action", "topicArn"],
        "arn:aws:sns:us-east-1:123456789012:attacker"
      ),
      put_in(json, ["receipt", "action", "bucketName"], "attacker"),
      put_in(json, ["receipt", "action", "objectKey"], "incoming/other-message"),
      put_in(json, ["receipt", "action", "objectKey"], "incoming/ses-123"),
      put_in(json, ["receipt", "action", "objectKey"], "../ses-123"),
      update_in(json, ["receipt"], &Map.delete(&1, "dkimVerdict")),
      %{"Records" => [%{"s3" => %{}}]}
    ]

    for value <- bad do
      assert {:error, :invalid_ses_receipt} =
               Receipt.parse(config, Content.new(Jason.encode!(value)))
    end
  end

  test "invalid configuration and oversized message cannot reach SDK" do
    assert {:error, :invalid_mail_configuration} = Config.new(sender: "bad")

    assert {:error, :invalid_outgoing_content} =
             Message.new("injected\r\nBcc: bad@example.com", Content.new("text"))

    assert {:error, :invalid_outgoing_content} =
             Message.new("subject", Content.new(String.duplicate("x", 131_073)))
  end

  test "SQS pull returns only redacted transient notification and receipt handle" do
    config =
      F.config(fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          "<ReceiveMessageResponse><ReceiveMessageResult><Message><MessageId>id</MessageId><ReceiptHandle>PRIVATE-HANDLE</ReceiptHandle><Body>PRIVATE-NOTIFICATION</Body><MD5OfBody>x</MD5OfBody></Message></ReceiveMessageResult></ReceiveMessageResponse>"
        )
      end)

    assert {:ok, [%{body: body, handle: handle} = message]} = SDK.poll(config)
    assert Content.read(body) == "PRIVATE-NOTIFICATION"
    assert Content.read(handle) == "PRIVATE-HANDLE"
    refute inspect(message) =~ "PRIVATE-"
  end

  test "malformed SDK XML cannot leak into logs, and ordinary caller logging resumes" do
    config = F.config(fn conn -> Plug.Conn.send_resp(conn, 200, "<PRIVATE-MAIL-SENTINEL") end)
    {:ok, prepared} = SDK.prepare(config)
    before_level = Logger.get_process_level(self())

    log =
      capture_log(fn ->
        assert {:error, :unresolved_delivery} = SDK.send(config, prepared, F.inbox(), F.message())
        Logger.warning("ordinary-mail-caller-still-logs")
      end)

    assert Logger.get_process_level(self()) == before_level
    refute log =~ "PRIVATE-MAIL-SENTINEL"
    assert log =~ "ordinary-mail-caller-still-logs"
  end

  test "MIME HTML doctype remains transient content, not an XML parser input" do
    body =
      "MIME-Version: 1.0\r\nContent-Type: text/html\r\n\r\n<!DOCTYPE html><html>PRIVATE-MAIL-SENTINEL</html>"

    config = F.config(fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
    assert {:ok, content} = SDK.fetch(config, "incoming/ses-mime")
    assert Content.read(content) == body
    refute inspect(content) =~ "PRIVATE-MAIL"
  end

  test "truncated S3 pages without NextMarker resume after the last listed object" do
    config =
      F.config(fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          "<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>incoming/last</Key><LastModified>2026-11-01T00:00:00Z</LastModified><Size>1</Size></Contents></ListBucketResult>"
        )
      end)

    assert {:ok, [%{key: "incoming/last"}], "incoming/last"} = SDK.list(config)
  end

  test "large forward has a typed terminal error without downloading its body" do
    parent = self()

    config = %{
      F.config(fn _ -> flunk("body downloaded") end)
      | test_plug: fn conn ->
          send(parent, {:method, conn.method})
          assert conn.method == "HEAD"

          conn
          |> Plug.Conn.put_resp_header("content-length", "1048577")
          |> Plug.Conn.send_resp(200, "")
        end
    }

    assert {:error, :mail_too_large} = SDK.fetch(config, "incoming/oversized")
    assert_received {:method, "HEAD"}
    refute_received {:method, "GET"}
  end

  test "growth after the size check is still a terminal size error" do
    config =
      F.config(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 1_048_577)) end)

    assert {:error, :mail_too_large} = SDK.fetch(config, "incoming/growing")
  end
end
