defmodule EmailJanitor.ConversationPlanTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Content
  alias EmailJanitor.Conversation.{Plan, Reference}

  defp object(overrides \\ %{}) do
    Map.merge(
      %{
        "replace_instructions" => [],
        "operation" => "answer",
        "references" => [],
        "preference_target" => "none",
        "instruction" => "",
        "query" => "",
        "reply" => "Which email do you mean?"
      },
      overrides
    )
  end

  test "a correction can restore and teach together without retaining raw plan text in inspection" do
    raw =
      object(%{
        "replace_instructions" => [],
        "operation" => "restore",
        "references" => ["ref_a"],
        "preference_target" => "inbox",
        "instruction" => "Keep invitations from people I know.",
        "reply" => "TRANSIENT_REPLY_MARKER"
      })

    assert {:ok, plan} = Plan.parse(Jason.encode!(raw), ["ref_a"])
    assert plan.operation == :restore
    assert Content.read(plan.instruction) == "Keep invitations from people I know."
    refute inspect(plan) =~ "TRANSIENT_REPLY_MARKER"
    refute inspect(plan) =~ "people I know"
    refute Jason.encode!(plan.instruction) =~ "people I know"
  end

  test "search is read-only and cannot be bundled with a guessed instruction or selection" do
    search = object(%{"operation" => "search", "query" => "from:bob@example.org"})
    assert {:ok, %{operation: :search}} = Plan.parse(search, ["ref_a"])

    for change <- [
          %{"references" => ["ref_a"]},
          %{"preference_target" => "all", "instruction" => "Discard Bob."}
        ] do
      assert {:error, :invalid_conversation_plan} =
               Plan.parse(Map.merge(search, change), ["ref_a"])
    end
  end

  test "the model cannot select invented, repeated or out-of-scope references" do
    for refs <- [["foreign"], ["ref_a", "ref_a"], List.duplicate("ref_a", 6), "ref_a", [123]] do
      assert {:error, :invalid_conversation_plan} =
               Plan.parse(object(%{"operation" => "done", "references" => refs}), ["ref_a"])
    end

    assert {:ok, _} =
             Plan.parse(object(%{"operation" => "done", "references" => ["ref_a"]}), ["ref_a"])
  end

  test "distilled corrections reject a complete short body and copied long passages" do
    short = "Buy my developer services today."

    passage =
      "This is a wholly synthetic cold outreach pitch with unique words describing an unsolicited service. "

    for {instruction, body} <- [
          {"Always discard: " <> short, short},
          {"Rule: " <> passage, String.duplicate(passage, 30)}
        ] do
      raw = object(%{"preference_target" => "inbox", "instruction" => instruction})
      assert {:error, :invalid_conversation_plan} = Plan.parse(raw, [], [Content.new(body)])
    end

    assert {:ok, _} =
             Plan.parse(
               object(%{
                 "preference_target" => "inbox",
                 "instruction" => "Mark unsolicited development offers Done."
               }),
               [],
               [Content.new(short)]
             )
  end

  test "fixed contract rejects unknown authority, controls, invalid UTF-8 and unbounded strings" do
    for raw <- [
          Map.put(object(), "scope", "ej_foreign"),
          Map.put(object(), "operation", "send"),
          Map.put(object(), "reply", <<255>>),
          Map.put(object(), "instruction", "hello\e[31m"),
          Map.put(object(), "reply", String.duplicate("x", 2049)),
          Map.put(object(), "query", String.duplicate("x", 513)),
          Map.put(object(), "preference_target", "foreign")
        ] do
      assert {:error, :invalid_conversation_plan} = Plan.parse(raw, [])
    end
  end

  test "a selected scope can be explicitly cleared, but dangling instructions and selections are invalid" do
    assert {:ok, %{preference_target: :all}} =
             Plan.parse(
               object(%{"preference_target" => "all", "replace_instructions" => ["$clear"]}),
               []
             )

    for raw <- [
          object(%{"instruction" => "Keep everything."}),
          object(%{"operation" => "done"}),
          object(%{
            "replace_instructions" => [],
            "operation" => "answer",
            "references" => ["ref_a"]
          })
        ] do
      assert {:error, :invalid_conversation_plan} = Plan.parse(raw, ["ref_a"])
    end
  end

  test "reference metadata is validated, redacted and inbox bound" do
    assert {:ok, a} =
             Reference.new(
               "inbox-a",
               "abc123",
               "def456",
               "Bob <bob@example.org>",
               "PRIVATE_SUBJECT"
             )

    assert {:ok, b} = Reference.new("inbox-b", "abc123", "def456", "Bob", "Hello")
    assert a.token != b.token
    refute inspect(a) =~ "PRIVATE_SUBJECT"

    assert {:error, :invalid_reference} =
             Reference.new("inbox-a", "abc123", "def456", "Bob\nINJECT", "Hello")

    assert {:error, :invalid_reference} =
             Reference.new("inbox-a", "bad/id", "def456", "Bob", "Hello")
  end
end
