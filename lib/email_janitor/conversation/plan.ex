defmodule EmailJanitor.Conversation.Plan do
  @moduledoc "A transient, validated proposal. Only host-supplied reference tokens can authorize a selection."
  alias EmailJanitor.Content
  @derive {Inspect, only: [:operation, :references, :preference_target]}
  defstruct [:operation, :references, :preference_target, :instruction, :query, :reply]

  @keys ~w(operation references preference_target instruction query reply)
  @operations ~w(answer search done restore)
  @targets ~w(none inbox all)
  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => @keys,
    "properties" => %{
      "operation" => %{"type" => "string", "enum" => @operations},
      "references" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "maxItems" => 5
      },
      "preference_target" => %{"type" => "string", "enum" => @targets},
      "instruction" => %{"type" => "string", "maxLength" => 15_000},
      "query" => %{"type" => "string", "maxLength" => 512},
      "reply" => %{"type" => "string", "maxLength" => 2048}
    }
  }

  def schema, do: @schema

  def parse(object, allowed_references, source_bodies \\ []) do
    with {:ok, value} <- object(object),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         true <- value["operation"] in @operations,
         true <- value["preference_target"] in @targets,
         true <- references?(value["references"], allowed_references),
         true <- text?(value["instruction"], 15_000),
         true <- text?(value["query"], 512),
         true <- text?(value["reply"], 2048),
         true <- compatible?(value),
         true <- distilled?(value["instruction"], source_bodies) do
      {:ok,
       %__MODULE__{
         operation: operation(value["operation"]),
         references: value["references"],
         preference_target: target(value["preference_target"]),
         instruction: Content.new(value["instruction"]),
         query: Content.new(value["query"]),
         reply: Content.new(value["reply"])
       }}
    else
      _ -> {:error, :invalid_conversation_plan}
    end
  rescue
    _ -> {:error, :invalid_conversation_plan}
  catch
    _, _ -> {:error, :invalid_conversation_plan}
  end

  defp object(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp object(value) when is_binary(value) and byte_size(value) <= 32_000, do: Jason.decode(value)
  defp object(_), do: {:error, :invalid_object}

  defp references?(references, allowed) do
    is_list(references) and length(references) <= 5 and
      length(Enum.uniq(references)) == length(references) and
      Enum.all?(references, &(is_binary(&1) and &1 in allowed))
  end

  defp text?(value, limit) do
    is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
      not Regex.match?(~r/[\x00-\x08\x0B-\x1F\x7F]/u, value)
  end

  defp compatible?(%{"operation" => operation} = value) do
    selected = value["references"] != []
    learning = value["preference_target"] != "none"
    query = String.trim(value["query"]) != ""
    instruction = String.trim(value["instruction"]) != ""

    (learning or not instruction) and
      case operation do
        "search" -> query and not selected and not learning
        "answer" -> not query and not selected
        _ -> selected and not query
      end
  end

  # Persistence accepts distilled instructions only. Do not let a model turn a
  # copied body (including a short complete body) into durable preference text.
  # This guard complements the prompt; source bodies themselves remain transient.
  defp distilled?("", _), do: true

  defp distilled?(instruction, sources) do
    normalized = normalize(instruction)

    Enum.all?(sources, fn %Content{} = source ->
      body = normalize(Content.read(source))

      cond do
        byte_size(body) < 12 -> true
        String.contains?(normalized, body) -> false
        true -> not copied_passage?(normalized, body)
      end
    end)
  end

  defp copied_passage?(instruction, body) do
    body
    |> String.graphemes()
    |> Enum.chunk_every(64, 16, :discard)
    |> Enum.any?(fn chunk -> String.contains?(instruction, Enum.join(chunk)) end)
  end

  defp normalize(text),
    do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp operation("answer"), do: :answer
  defp operation("search"), do: :search
  defp operation("done"), do: :done
  defp operation("restore"), do: :restore
  defp target("none"), do: :none
  defp target("inbox"), do: :inbox
  defp target("all"), do: :all
end
