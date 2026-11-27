defmodule EmailJanitor.ConversationEvidenceTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Content
  alias EmailJanitor.Conversation.Evidence

  test "forwarded evidence has bounded fields and redacted inspection" do
    assert {:ok, evidence} =
             Evidence.new("sender@example.org", "Subject", Content.new("PRIVATE_FORWARDED_BODY"))

    assert {:ok,
            %{
              "sender" => "sender@example.org",
              "subject" => "Subject",
              "body" => "PRIVATE_FORWARDED_BODY"
            }} = Evidence.decode(evidence)

    refute inspect(evidence) =~ "PRIVATE_FORWARDED_BODY"
    assert {:ok, nil} = Evidence.decode(nil)
    assert {:ok, _} = Evidence.new("", "", Content.new(String.duplicate("a", 8_000)))
  end

  test "malformed, oversized and extra capability fields fail closed" do
    for {sender, subject, body} <- [
          {nil, "", ""},
          {"", "a\r\nb", ""},
          {"a\nb", "", ""},
          {String.duplicate("a", 1_025), "", ""},
          {"", "", String.duplicate("a", 8_001)},
          {"", "", <<255>>},
          {"", "", <<0>>}
        ] do
      assert {:error, :invalid_request_evidence} =
               Evidence.new(sender, subject, Content.new(body))
    end

    for raw <- [
          "invalid",
          "[]",
          "null",
          String.duplicate("a", 64_001),
          Jason.encode!(%{sender: "", subject: "", body: "", inbox_id: "forged"})
        ] do
      assert {:error, :invalid_request_evidence} = Evidence.decode(Content.new(raw))
    end
  end

  test "JSON escaping at the body boundary stays within the decoder cap" do
    assert {:ok, evidence} = Evidence.new("", "", Content.new(String.duplicate("\t", 8_000)))
    assert {:ok, value} = Evidence.decode(evidence)
    assert value["body"] == String.duplicate("\t", 8_000)
  end
end
