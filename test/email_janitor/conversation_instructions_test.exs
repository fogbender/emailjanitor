defmodule EmailJanitor.ConversationInstructionsTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Content
  alias EmailJanitor.Conversation.{Instructions, Plan}

  test "a small edit preserves a near-capacity scope without regenerating unrelated instructions" do
    paragraphs = for index <- 1..14, do: "Rule #{index}: " <> String.duplicate("a", 890)
    current = Content.new(Enum.join(paragraphs, "\n\n"))
    [_first, selected | _] = Instructions.entries(current)
    addition = Content.new("Keep requested customer research.")
    assert {:ok, edited} = Instructions.edit(current, [selected.id], addition)

    assert Content.read(edited) ==
             Enum.join(List.delete_at(paragraphs, 1) ++ [Content.read(addition)], "\n\n")

    assert {:ok, same} = Instructions.edit(edited, [], addition)
    assert Content.read(same) == Content.read(edited)
    assert {:ok, empty} = Instructions.edit(current, ["$clear"], Content.new(""))
    assert Content.read(empty) == ""
  end

  test "instruction selection is scoped, finite and supports explicit removal" do
    all = Instructions.entries(Content.new("All-inbox rule."))
    local = Instructions.entries(Content.new("Local rule."))
    [%{id: all_id}] = all
    [%{id: local_id}] = local

    object = %{
      "operation" => "answer",
      "references" => [],
      "preference_target" => "inbox",
      "instruction" => "",
      "replace_instructions" => [local_id],
      "query" => "",
      "reply" => ""
    }

    refs = %{all: [all_id], inbox: [local_id]}
    assert {:ok, _} = Plan.parse(object, [], [], refs)

    assert {:error, :invalid_conversation_plan} =
             Plan.parse(%{object | "replace_instructions" => [all_id]}, [], [], refs)

    assert {:error, :invalid_conversation_plan} =
             Plan.parse(%{object | "instruction" => String.duplicate("x", 1001)}, [], [], refs)

    assert {:error, :invalid_instruction_edit} =
             Instructions.edit(Content.new("Local rule."), [all_id], Content.new(""))

    assert {:ok, empty} =
             Instructions.edit(Content.new("Local rule."), [local_id], Content.new(" \n\t "))

    assert Content.read(empty) == ""
  end

  test "many short paragraphs remain within a bounded model reference budget" do
    current = Content.new(Enum.join(for(n <- 1..1000, do: "Rule #{n}."), "\n\n"))
    assert length(Instructions.entries(current)) <= 64
    assert {:ok, same} = Instructions.edit(current, [], Content.new(""))
    assert Content.read(same) == Content.read(current)
  end
end
