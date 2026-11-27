defmodule EmailJanitor.DigestWireCapture do
  @behaviour ExAws.Request.HttpClient
  def request(:post, url, body, headers, opts) do
    decoded = URI.decode_query(body)["Message.Body.Text.Data"]

    signed =
      Enum.any?(headers, fn {key, value} ->
        String.downcase(key) == "authorization" and String.contains?(value, "AWS4-HMAC-SHA256")
      end)

    send(opts[:observer], {:wire, url, byte_size(body), :crypto.hash(:sha256, decoded), signed})

    {:ok,
     %{
       status_code: 200,
       headers: [],
       body:
         "<SendEmailResponse><SendEmailResult><MessageId>wire-proof</MessageId></SendEmailResult></SendEmailResponse>"
     }}
  end
end

defmodule EmailJanitor.DigestWireSizeTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, Inbox}
  alias EmailJanitor.Mail.{Message, SDK}
  alias EmailJanitor.MailFixture, as: F

  test "actual maintained SES SDK worst-case UTF-8 POST and MIME bounds remain below 10 MB" do
    bytes = Message.max_text_bytes()
    text = String.duplicate("€", div(bytes, 3))
    {:ok, message} = Message.new(String.duplicate("€", 85), Content.new(text))

    address =
      String.duplicate("a", 64) <>
        "@" <>
        String.duplicate("b", 63) <>
        "." <> String.duplicate("c", 63) <> "." <> String.duplicate("d", 49) <> ".example.com"

    {:ok, inbox} = Inbox.new("wire", address)

    config =
      F.config(fn _ -> flunk("Req.Plug's 1 MB form parser is not this SDK wire-size test") end)

    config = %{config | sender: address}
    {:ok, prepared} = SDK.prepare(config)
    # Capture the maintained SDK's encoded/signed HTTP boundary. Req.Plug has a
    # fixed 1 MB form parser, unrelated to SES's supported email message size.
    prepared = %{
      prepared
      | options:
          prepared.options
          |> Keyword.put(:http_client, EmailJanitor.DigestWireCapture)
          |> Keyword.put(:http_opts, observer: self())
    }

    assert {:ok, _} = SDK.send(config, prepared, inbox, message)
    assert_received {:wire, "https://email.us-east-1.amazonaws.com/", size, digest, true}
    assert digest == :crypto.hash(:sha256, text)
    assert size < 10_000_000
    assert size > 9_000_000
    # SES owns MIME generation. Both conservative UTF-8 encodings, line wrapping
    # and a 16 KiB header allowance stay below the documented v1 message quota.
    base64 = 4 * div(bytes + 2, 3)
    assert base64 + 2 * div(base64 + 75, 76) + 16_384 < 10_000_000
    quoted_printable = 3 * bytes
    assert quoted_printable + 3 * div(quoted_printable + 72, 73) + 16_384 < 10_000_000
  end
end
