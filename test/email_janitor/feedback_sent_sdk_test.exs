defmodule EmailJanitor.FeedbackSentSDKTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Fixtures}
  alias EmailJanitor.Gmail.{Config, SDK}
  alias EmailJanitor.Mail.RFCMessageID

  defp options do
    {:ok, config} =
      Config.new(Fixtures.inbox(), fn -> {:ok, Content.new("PRIVATE_SENT_TOKEN")} end,
        adapter: Tesla.Mock
      )

    [config: config]
  end

  defp sent(headers \\ [], labels \\ ["SENT"]) do
    %{
      "id" => "sent-1",
      "threadId" => "thread-1",
      "internalDate" => "1795708800000",
      "labelIds" => labels,
      "payload" => %{
        "mimeType" => "text/plain",
        "filename" => "",
        "headers" =>
          [
            %{"name" => "From", "value" => "owner@acme.com"},
            %{"name" => "To", "value" => "janitor@example.com"},
            %{"name" => "Message-ID", "value" => "<safe+id=1@EXAMPLE.COM>"}
          ] ++ headers,
        "body" => %{"data" => Base.url_encode64("AUTHENTIC_USER_TEXT", padding: false)}
      }
    }
  end

  defp mock(fun) do
    Tesla.Mock.mock(fn env ->
      assert {"authorization", "Bearer PRIVATE_SENT_TOKEN"} in env.headers

      if String.ends_with?(env.url, "/profile"),
        do: Tesla.Mock.json(%{"emailAddress" => "owner@acme.com", "historyId" => "100"}),
        else: fun.(env)
    end)
  end

  test "canonical references are bounded and cannot widen the Gmail query; request IDs are mailbox scoped" do
    assert {:ok, id} = RFCMessageID.canonical(" <safe+id=1@EXAMPLE.COM> ")
    assert id == "safe+id=1@example.com"

    for bad <- [
          "<x@example.com> OR in:anywhere",
          "x@example.com\nBcc:victim@example.com",
          "x\"@example.com",
          "x@bad..com",
          "x@-bad.com",
          String.duplicate("x", 601),
          nil
        ] do
      assert {:error, :invalid_message_id} = RFCMessageID.canonical(bad)
    end

    assert {:ok, uuid} = RFCMessageID.request_id("box-a", id)
    assert {:ok, ^uuid} = RFCMessageID.request_id("box-a", id)
    assert {:ok, other} = RFCMessageID.request_id("box-b", id)
    refute uuid == other
  end

  test "only a unique fully fetched current Sent copy crosses the SDK boundary" do
    mock(fn env ->
      case URI.parse(env.url).path do
        "/gmail/v1/users/me/messages" ->
          assert env.query[:q] == ~s(in:sent rfc822msgid:"safe+id=1@example.com")
          assert env.query[:maxResults] == 2
          Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1", "threadId" => "thread-1"}]})

        "/gmail/v1/users/me/messages/sent-1" ->
          assert env.query[:format] == "full"
          Tesla.Mock.json(sent())

        _ ->
          flunk("Unexpected SDK operation")
      end
    end)

    assert {:ok, message} = SDK.feedback_sent("inbox-1", "safe+id=1@example.com", options())
    assert Content.read(message.body) == "AUTHENTIC_USER_TEXT"
    assert DateTime.compare(message.received_at, ~U[2026-11-26 16:00:00Z]) == :eq
    assert message.feedback_format == :plain
    refute inspect(message) =~ "AUTHENTIC_USER_TEXT"
  end

  for {value, reason} <- [
        {%{}, :sent_not_indexed},
        {%{"messages" => [%{"id" => "a"}, %{"id" => "b"}]}, :ambiguous_sent},
        {%{"messages" => [%{"id" => "a"}], "nextPageToken" => "more"}, :ambiguous_sent}
      ] do
    test "search #{reason} #{inspect(value)} never downloads an arbitrary first result" do
      value = unquote(Macro.escape(value))
      reason = unquote(reason)

      mock(fn env ->
        assert URI.parse(env.url).path == "/gmail/v1/users/me/messages"
        Tesla.Mock.json(value)
      end)

      assert {:error, ^reason} = SDK.feedback_sent("inbox-1", "safe+id=1@example.com", options())
    end
  end

  test "stale index, missing SENT, duplicate/wrong Message-ID and resource mismatches never authenticate" do
    for response <- [
          sent([], ["INBOX"]),
          sent([%{"name" => "Message-ID", "value" => "<other@example.com>"}]),
          Map.put(sent(), "id", "another")
        ] do
      mock(fn env ->
        if URI.parse(env.url).path == "/gmail/v1/users/me/messages",
          do: Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]}),
          else: Tesla.Mock.json(response)
      end)

      assert {:error, :invalid_sent_message} =
               SDK.feedback_sent("inbox-1", "safe+id=1@example.com", options())
    end

    mock(fn env ->
      if URI.parse(env.url).path == "/gmail/v1/users/me/messages",
        do: Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]}),
        else: %Tesla.Env{status: 404, body: "PRIVATE_RESOURCE_ERROR"}
    end)

    assert {:error, :sent_not_indexed} =
             SDK.feedback_sent("inbox-1", "safe+id=1@example.com", options())
  end

  test "plain alternative wins over duplicated HTML; HTML-only and attached forwards are explicit" do
    base = sent()
    plain = base["payload"]

    html = %{
      plain
      | "mimeType" => "text/html",
        "body" => %{
          "data" => Base.url_encode64("<p>QUOTED_COMMAND_NOT_AUTHORED</p>", padding: false)
        }
    }

    for {payload, format, expected} <- [
          {%{
             "mimeType" => "multipart/alternative",
             "headers" => plain["headers"],
             "parts" => [plain, html]
           }, :plain, "AUTHENTIC_USER_TEXT"},
          {html, :html, "QUOTED_COMMAND_NOT_AUTHORED"},
          {%{
             "mimeType" => "multipart/mixed",
             "headers" => plain["headers"],
             "parts" => [
               plain,
               %{
                 "mimeType" => "message/rfc822",
                 "filename" => "original.eml",
                 "body" => %{"attachmentId" => "opaque"}
               }
             ]
           }, :ambiguous, "AUTHENTIC_USER_TEXT"}
        ] do
      mock(fn env ->
        if URI.parse(env.url).path == "/gmail/v1/users/me/messages",
          do: Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]}),
          else: Tesla.Mock.json(%{base | "payload" => payload})
      end)

      assert {:ok, message} = SDK.feedback_sent("inbox-1", "safe+id=1@example.com", options())
      assert message.feedback_format == format
      assert Content.read(message.body) == expected
    end
  end

  test "bad identifiers never resolve credentials, and SDK errors remain fixed and unlogged" do
    {:ok, config} =
      Config.new(Fixtures.inbox(), fn -> flunk("Invalid reference must not resolve tokens") end)

    assert {:error, :invalid_message_id} =
             SDK.feedback_sent("inbox-1", "x@example.com OR in:anywhere", config: config)

    mock(fn _ -> %Tesla.Env{status: 500, body: "PRIVATE_RESOURCE_ERROR"} end)

    logs =
      capture_log(fn ->
        assert {:error, :gmail_unavailable} =
                 SDK.feedback_sent("inbox-1", "safe+id=1@example.com", options())
      end)

    refute logs =~ "PRIVATE_RESOURCE_ERROR"
    refute logs =~ "PRIVATE_SENT_TOKEN"
  end
end
