defmodule EmailJanitor.ReviewerTest do
  use ExUnit.Case, async: true
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Message, Proposal, Reviewer, TestClassifier}

  defp review(messages, opts \\ [], contacts \\ MapSet.new(), restored \\ MapSet.new()) do
    Reviewer.review(
      messages,
      inbox(),
      contacts,
      {TestClassifier, [notify: self()] ++ opts},
      "Keep customer inquiries.",
      1,
      restored
    )
  end

  test "clear pitch produces exact inbox IDs and no body-bearing result" do
    messages = [message(), message(id: "old", labels: [])]
    assert {:ok, %Proposal{message_ids: ["message-1"]} = proposal} = review(messages)
    refute inspect(proposal) =~ "Synthetic"
    assert_receive {:classified, 2, "Keep customer inquiries."}
  end

  test "sent and draft conversations bypass the model" do
    for label <- ["SENT", "DRAFT"] do
      assert {:keep, :sent_or_draft} = review([message(labels: ["INBOX", label])])
      refute_received {:classified, _, _}
    end
  end

  test "prior contacts and manual restorations bypass the model" do
    assert {:keep, :prior_correspondence} = review([message()], [], MapSet.new(["vendor.com"]))

    assert {:keep, :manually_restored} =
             review([message()], [], MapSet.new(), MapSet.new(["message-1"]))

    refute_received {:classified, _, _}
  end

  test "low confidence never proposes a mutation" do
    assert {:keep, :classifier_kept} =
             review([message()],
               result: %{"action" => "done", "confidence" => "low", "category" => "cold_outreach"}
             )
  end

  test "empty and archived threads cannot produce an action" do
    assert {:keep, :empty_thread} = review([])
    assert {:keep, :no_matching_inbox_messages} = review([message(labels: [])])
  end

  test "mixed thread IDs cannot be mutated as one thread" do
    assert {:keep, :no_matching_inbox_messages} =
             review([message(), message(id: "other", thread_id: "other")])
  end

  test "fingerprint detects new messages and label changes independently of order" do
    a = message()
    b = message(id: "second")
    assert Message.fingerprint([a, b]) == Message.fingerprint([b, a])
    refute Message.fingerprint([a]) == Message.fingerprint([a, b])
    refute Message.fingerprint([a]) == Message.fingerprint([%{a | labels: ["INBOX"]}])
  end
end
