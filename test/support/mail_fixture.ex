defmodule EmailJanitor.MailFixture do
  alias EmailJanitor.{Content, Inbox}
  alias EmailJanitor.Mail.{Config, Message, Receipt}

  def config(plug) do
    {:ok, config} =
      Config.new(
        region: "us-east-1",
        sender: "janitor@janitor.example.com",
        bucket: "janitor-spool",
        queue_url: "https://sqs.us-east-1.amazonaws.com/123456789012/janitor-mail",
        topic_arn: "arn:aws:sns:us-east-1:123456789012:janitor-receipts",
        credentials: fn ->
          {:ok,
           [
             access_key_id: "synthetic-access",
             secret_access_key: "synthetic-secret",
             security_token: "synthetic-token"
           ]}
        end,
        test_plug: plug
      )

    config
  end

  def inbox do
    {:ok, inbox} = Inbox.new("mail-inbox", "owner@example.com")
    inbox
  end

  def message(text \\ "PRIVATE-MAIL-SENTINEL") do
    {:ok, message} = Message.new("Daily activity", Content.new(text))
    message
  end

  def receipt(config, id \\ "ses-123", at \\ DateTime.utc_now()) do
    json = %{
      "notificationType" => "Received",
      "mail" => %{
        "messageId" => id,
        "source" => "owner@example.com",
        "commonHeaders" => %{
          "from" => ["attacker@example.net"],
          "subject" => "PRIVATE-HEADER-SENTINEL"
        }
      },
      "receipt" => %{
        "timestamp" => DateTime.to_iso8601(at),
        "recipients" => [config.sender],
        "spamVerdict" => %{"status" => "PASS"},
        "virusVerdict" => %{"status" => "PASS"},
        "spfVerdict" => %{"status" => "PASS"},
        "dkimVerdict" => %{"status" => "PASS"},
        "dmarcVerdict" => %{"status" => "PASS"},
        "action" => %{
          "type" => "S3",
          "topicArn" => config.topic_arn,
          "bucketName" => config.bucket,
          "objectKey" => "incoming/" <> id
        }
      }
    }

    {:ok, receipt} = Receipt.parse(config, Content.new(Jason.encode!(json)))
    {receipt, json}
  end

  def ses_response(conn, id \\ "ses-outgoing-123") do
    Plug.Conn.send_resp(
      conn,
      200,
      "<SendEmailResponse><SendEmailResult><MessageId>#{id}</MessageId></SendEmailResult><ResponseMetadata><RequestId>request</RequestId></ResponseMetadata></SendEmailResponse>"
    )
  end
end
