defmodule EmailJanitor.Conversation.Instructions do
  @moduledoc "Small edits preserve unrelated paragraphs without rewriting an entire preference scope."
  alias EmailJanitor.Content

  def entries(%Content{} = content) do
    Content.read(content)
    |> String.split("\n\n", trim: true)
    |> group_paragraphs()
    |> Enum.map(fn text ->
      %{
        id:
          "rule_" <> binary_part(Base.encode16(:crypto.hash(:sha256, text), case: :lower), 0, 24),
        text: Content.new(text)
      }
    end)
  end

  defp group_paragraphs(paragraphs) do
    size = max(1, div(length(paragraphs) + 63, 64))
    Enum.chunk_every(paragraphs, size) |> Enum.map(&Enum.join(&1, "\n\n"))
  end

  def edit(%Content{} = current, remove, %Content{} = addition) do
    entries = entries(current)
    allowed = Enum.map(entries, & &1.id)
    text = Content.read(addition)

    cond do
      remove == ["$clear"] and text == "" ->
        {:ok, Content.new("")}

      is_list(remove) and length(remove) <= 5 and Enum.all?(remove, &(&1 in allowed)) and
          byte_size(text) <= 1_000 ->
        remaining = Enum.reject(entries, &(&1.id in remove)) |> Enum.map(&Content.read(&1.text))
        parts = if text == "" or text in remaining, do: remaining, else: remaining ++ [text]
        next = Enum.join(parts, "\n\n")

        if byte_size(next) <= 15_000,
          do: {:ok, Content.new(next)},
          else: {:error, :instruction_capacity}

      true ->
        {:error, :invalid_instruction_edit}
    end
  rescue
    _ -> {:error, :invalid_instruction_edit}
  end
end
