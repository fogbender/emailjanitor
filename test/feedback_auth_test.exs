defmodule EmailJanitor.FeedbackAuthTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.{Content, Inbox, Message}
  alias EmailJanitor.Mail.Incoming
  alias EmailJanitor.Mail.Feedback.{Auth, Envelope}
  @at ~U[2026-11-27 12:00:00.000000Z]
  defp sent do
    %Message{
      id: "s",
      thread_id: "t",
      labels: ["SENT"],
      received_at: @at,
      feedback_format: :plain,
      headers: [
        {"From", "Owner <owner@example.com>"},
        {"To", "Janitor <janitor@example.com>"},
        {"Message-ID", "<m@example.com>"},
        {"Date", "Fri, 1 Jan 2099 00:00:00 +0000"}
      ],
      body: Content.new("REAL_USER_MESSAGE")
    }
  end

  defp box do
    {:ok, inbox} = Inbox.new("owner", "owner@example.com")
    inbox
  end

  defp verify(message),
    do: Auth.verify(message, box(), "m@example.com", "janitor@example.com", @at)

  test "current From, exact Message-ID, Sent and Janitor recipient are independent requirements" do
    assert :ok = verify(sent())

    for labels <- [[], ["INBOX"], ["SENT", "DRAFT"], ["SENT", "TRASH"], ["SENT", "SPAM"]] do
      assert {:error, :unverified_sent_copy} = verify(%{sent() | labels: labels})
    end

    for {key, value} <- [
          {"From", "other@example.com"},
          {"To", "other@example.com"},
          {"Message-ID", "<other@example.com>"}
        ] do
      changed = %{
        sent()
        | headers:
            Enum.map(sent().headers, fn {k, v} -> if k == key, do: {k, value}, else: {k, v} end)
      }

      assert {:error, :unverified_sent_copy} = verify(changed)
    end

    assert {:error, :unverified_sent_copy} =
             verify(%{sent() | headers: sent().headers ++ [{"From", "owner@example.com"}]})

    bcc = %{
      sent()
      | headers: [
          {"Bcc", "janitor@example.com"} | Enum.reject(sent().headers, fn {k, _} -> k == "To" end)
        ]
    }

    assert :ok = verify(bcc)
  end

  test "Gmail internal date is compared to trusted SES time, never the mutable Date header" do
    assert :ok = verify(%{sent() | received_at: DateTime.add(@at, -3600)})

    assert {:error, :unverified_sent_copy} =
             verify(%{sent() | received_at: DateTime.add(@at, -3_600_001, :millisecond)})

    assert {:error, :unverified_sent_copy} =
             verify(%{sent() | received_at: DateTime.add(@at, 301)})
  end

  test "raw framing preserves duplicate rejection and exposes no SMTP References or body routing capability" do
    incoming = %Incoming{
      id: "ses",
      recipients: ["janitor@example.com"],
      envelope_from: "owner@example.com",
      verdicts:
        Map.new(~w(spamVerdict virusVerdict spfVerdict dkimVerdict dmarcVerdict), &{&1, "PASS"}),
      expires_at: DateTime.add(@at, 3600)
    }

    raw =
      "From: Owner <owner@example.com>\r\nMessage-ID: <m@example.com>\r\nReferences: <attacker-context@amazonses.com>\r\n\r\nRAW_SMTP_COMMAND"

    assert {:ok, envelope} = Envelope.new(incoming, Content.new(raw), "janitor@example.com")
    assert envelope.signup_allowed
    refute inspect(envelope) =~ "RAW_SMTP_COMMAND"
    refute Map.has_key?(Map.from_struct(envelope), :references)
    duplicate = String.replace(raw, "\r\n\r\n", "\r\nFrom: other@example.com\r\n\r\n")
    assert :rejected = Envelope.new(incoming, Content.new(duplicate), "janitor@example.com")

    assert Envelope.new(
             incoming,
             Content.new(String.replace(raw, "\r\n", "\n")),
             "janitor@example.com"
           ) in [:ignored, :rejected]
  end
end
