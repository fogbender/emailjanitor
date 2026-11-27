defmodule EmailJanitor.MailThreadingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmailJanitor.Content
  alias EmailJanitor.Mail.{Message, SDK}
  alias EmailJanitor.MailFixture, as: F

  defp response(conn),
    do:
      Plug.Conn.send_resp(
        conn,
        200,
        "<SendRawEmailResponse><SendRawEmailResult><MessageId>ses-outgoing-123</MessageId></SendRawEmailResult><ResponseMetadata><RequestId>request</RequestId></ResponseMetadata></SendRawEmailResponse>"
      )

  test "reply metadata uses canonical bounded references without any recipient capability" do
    assert {:ok, reply} =
             Message.new(Content.new("Re: Hello"), Content.new("Private answer"),
               in_reply_to: "source@example.org"
             )

    assert reply.references == ["source@example.org"]
    refute inspect(reply) =~ "Private answer"
    refute Jason.encode!(reply) =~ "Private answer"

    for opts <- [
          [in_reply_to: "<source@example.org>"],
          [in_reply_to: "bad\r\nBcc: injected@example.org"],
          [in_reply_to: "source@example.org", references: []],
          [in_reply_to: "source@example.org", references: ["other@example.org"]],
          [
            in_reply_to: "source@example.org",
            references: List.duplicate("source@example.org", 2)
          ],
          [in_reply_to: "source@example.org", to: "other@example.org"]
        ] do
      assert {:error, :invalid_outgoing_content} =
               Message.new("Reply", Content.new("Answer"), opts)
    end

    assert {:error, :invalid_outgoing_content} =
             Message.new("Header\x01", Content.new("Answer"), in_reply_to: "source@example.org")

    assert {:error, :invalid_outgoing_content} =
             Message.new("Reply", Content.new(String.duplicate("a", 64_001)),
               in_reply_to: "source@example.org"
             )
  end

  test "the maintained SES SDK sends a single raw reply with host-owned addresses and correct MIME" do
    parent = self()

    config =
      F.config(fn conn ->
        {:ok, wire, conn} = Plug.Conn.read_body(conn)
        send(parent, {:wire, URI.decode_query(wire)})
        response(conn)
      end)

    subject = "Re: Réunion 漢字"
    body = "PRIVATE_REPLY_BODY\nUnicode: 漢字"

    {:ok, reply} =
      Message.new(subject, Content.new(body),
        in_reply_to: "source@example.org",
        references: ["earlier@example.org", "source@example.org"]
      )

    {:ok, prepared} = SDK.prepare(config)

    log =
      capture_log(fn ->
        assert {:ok, "ses-outgoing-123"} = SDK.send(config, prepared, F.inbox(), reply)
      end)

    refute log =~ "PRIVATE_REPLY_BODY"
    assert_received {:wire, params}
    refute_received {:wire, _}
    assert params["Action"] == "SendRawEmail"
    assert params["Source"] == config.sender
    raw = Base.decode64!(params["RawMessage.Data"])
    {headers, _} = :mimemail.parse_headers(raw)
    assert :mimemail.get_header_value("To", headers) == F.inbox().address
    assert :mimemail.get_header_value("From", headers) == config.sender
    assert :mimemail.get_header_value("In-Reply-To", headers) == "<source@example.org>"

    assert :mimemail.get_header_value("References", headers) ==
             "<earlier@example.org> <source@example.org>"

    assert Regex.match?(
             ~r/\A<[a-f0-9-]{36}@janitor\.example\.com>\z/,
             :mimemail.get_header_value("Message-ID", headers)
           )

    assert String.ends_with?(:mimemail.get_header_value("Date", headers), " +0000")
    [_, encoded_body] = String.split(raw, "\r\n\r\n", parts: 2)
    refute encoded_body =~ "=0A"
    refute encoded_body =~ "=0D"
    assert :mimemail.get_header_value("Bcc", headers) == :undefined
    assert :mimemail.get_header_value("Auto-Submitted", headers) == "auto-replied"
    decoded = Mail.parse(raw)
    assert Mail.get_subject(decoded) == subject
    assert String.replace(Mail.get_text(decoded).body, "\r\n", "\n") == body
    assert Enum.all?(String.split(raw, "\r\n"), &(byte_size(&1) <= 998))
  end

  test "large Unicode and ASCII subjects and bounded reply bodies stay within the wire limits" do
    parent = self()

    config =
      F.config(fn conn ->
        {:ok, wire, conn} = Plug.Conn.read_body(conn, length: 2_000_000)
        send(parent, {:wire, wire})
        response(conn)
      end)

    {:ok, prepared} = SDK.prepare(config)

    for subject <- [
          String.duplicate("X", 980),
          String.duplicate("漢", 326),
          "",
          "Re: a;b; c",
          ";Leading;  two spaces;",
          String.duplicate("X;", 490)
        ] do
      {:ok, reply} =
        Message.new(subject, Content.new(String.duplicate(<<1>>, 64_000)),
          in_reply_to: "source@example.org"
        )

      assert {:ok, _} = SDK.send(config, prepared, F.inbox(), reply)
      assert_receive {:wire, wire}
      assert byte_size(wire) < 1_000_000
      raw = wire |> URI.decode_query() |> Map.fetch!("RawMessage.Data") |> Base.decode64!()
      assert Enum.all?(String.split(raw, "\r\n"), &(byte_size(&1) <= 998))
      assert Mail.get_subject(Mail.parse(raw)) == subject
    end
  end

  test "forged header fields and destination structs cannot reach the network" do
    config = F.config(fn _ -> flunk("invalid reply reached network") end)
    {:ok, prepared} = SDK.prepare(config)
    {:ok, reply} = Message.new("Reply", Content.new("Answer"), in_reply_to: "source@example.org")

    assert {:error, :invalid_outgoing_content} =
             SDK.send(config, prepared, F.inbox(), %{
               reply
               | in_reply_to: "source@example.org\r\nBcc: other@example.org"
             })

    assert {:error, :invalid_outgoing_content} =
             SDK.send(
               config,
               prepared,
               %{F.inbox() | address: "owner@example.com\r\nBcc: other@example.org"},
               reply
             )
  end

  test "raw SES failures remain ambiguous and are never retried" do
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, :sent)
        Plug.Conn.send_resp(conn, 503, "PRIVATE_REPLY_BODY")
      end)

    {:ok, reply} =
      Message.new("Reply", Content.new("PRIVATE_REPLY_BODY"), in_reply_to: "source@example.org")

    {:ok, prepared} = SDK.prepare(config)

    log =
      capture_log(fn ->
        assert {:error, :unresolved_delivery} = SDK.send(config, prepared, F.inbox(), reply)
      end)

    assert_received :sent
    refute_received :sent
    refute log =~ "PRIVATE_REPLY_BODY"
  end
end
