defmodule EmailJanitor.Conversation.Plan do
  @moduledoc "A transient, validated proposal. Only host-supplied reference tokens can authorize a selection."
  alias EmailJanitor.Content
  @derive {Inspect, only: [:operation, :references, :preference_target]}
  defstruct [
    :operation,
    :references,
    :preference_target,
    :instruction,
    :query,
    :reply,
    replace_instructions: [],
    search_complete: false
  ]

  @keys ~w(operation references preference_target instruction replace_instructions query reply)
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
      "instruction" => %{"type" => "string", "maxLength" => 1_000},
      "replace_instructions" => %{
        "type" => "array",
        "maxItems" => 5,
        "items" => %{"type" => "string"}
      },
      "query" => %{"type" => "string", "maxLength" => 512},
      "reply" => %{"type" => "string", "maxLength" => 1024}
    }
  }

  def schema, do: @schema

  def parse(object, allowed_references, source_bodies \\ [], instruction_refs \\ %{}) do
    with {:ok, value} <- object(object),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(@keys),
         true <- value["operation"] in @operations,
         true <- value["preference_target"] in @targets,
         true <- references?(value["references"], allowed_references),
         true <- text?(value["instruction"], 1_000),
         true <- text?(value["query"], 512),
         true <- text?(value["reply"], 1024),
         true <-
           is_list(source_bodies) and length(source_bodies) <= 35 and
             Enum.all?(source_bodies, &valid_source?/1),
         true <- instruction_references?(value, instruction_refs),
         true <- compatible?(value),
         true <- distilled?(value["instruction"], source_bodies) do
      {:ok,
       %__MODULE__{
         operation: operation(value["operation"]),
         references: value["references"],
         preference_target: target(value["preference_target"]),
         replace_instructions: value["replace_instructions"],
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

  defp instruction_references?(value, refs) do
    selected = value["replace_instructions"]
    scope = target(value["preference_target"])

    is_list(selected) and length(selected) <= 5 and
      length(Enum.uniq(selected)) == length(selected) and
      cond do
        scope == :none -> selected == []
        selected == ["$clear"] -> value["instruction"] == ""
        true -> Enum.all?(selected, &(&1 in Map.get(refs, scope, [])))
      end
  end

  defp compatible?(%{"operation" => operation} = value) do
    selected = value["references"] != []
    learning = value["preference_target"] != "none"
    query = String.trim(value["query"]) != ""
    instruction = String.trim(value["instruction"]) != "" or value["replace_instructions"] != []

    learning == instruction and
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

    sources
    |> Enum.flat_map(&source_values/1)
    |> Enum.all?(fn {kind, raw} ->
      body = normalize(raw)

      cond do
        body == "" -> true
        normalized == body -> false
        kind in [:sender, :subject] -> not copied_header?(normalized, raw, kind)
        byte_size(body) < 12 -> true
        String.contains?(normalized, body) -> false
        true -> not copied_passage?(normalized, body)
      end
    end)
  end

  defp valid_source?(%Content{} = source), do: byte_size(Content.read(source)) <= 8_000

  defp valid_source?({kind, %Content{} = source}) when kind in [:sender, :subject],
    do: byte_size(Content.read(source)) <= 1_024

  defp valid_source?(_), do: false

  defp source_values(%Content{} = source), do: [{:body, Content.read(source)}]

  defp source_values({kind, source}) when kind in [:sender, :subject] do
    raw = Content.read(source)
    # Decode encoded words as unstructured text, so every display name, comment
    # and group is covered rather than only RFC2822's first From mailbox.
    decoded =
      try do
        {"subject", value} = Mail.Parsers.RFC2822.parse_header("Subject: " <> raw, [])
        if is_binary(value), do: value, else: raw
      rescue
        _ -> raw
      catch
        _, _ -> raw
      end

    [{kind, raw}, {kind, decoded}] |> Enum.uniq()
  end

  defp copied_header?(instruction, raw, kind) do
    addresses = if kind == :sender, do: sender_addresses(raw), else: []

    clean = fn text ->
      Enum.reduce(addresses, String.downcase(text), fn address, value ->
        String.replace(value, address, " ")
      end)
      |> String.replace(~r/[<>(),:;"]/u, " ")
      |> normalize()
    end

    identifier = clean.(raw)
    command = clean.(instruction)
    # Preserve ordinary names and subject identifiers. Longer verbatim header
    # phrases stay out of instructions; the teacher uses a canonical address or
    # a concise semantic description instead.
    (identifier != "" and identifier == command) or
      identifier
      |> String.graphemes()
      |> Enum.chunk_every(48, 1, :discard)
      |> Enum.any?(fn chunk -> String.contains?(command, Enum.join(chunk)) end)
  end

  defp sender_addresses(raw) do
    # The maintained To parser retains every mailbox; its From parser returns
    # only the first one. This syntactic identifier check does not require a
    # public suffix, so reserved fixture domains and local addresses are safe.
    {"to", parsed} = Mail.Parsers.RFC2822.parse_header("To: " <> raw, [])

    parsed
    |> carrier_values()
    |> Enum.filter(fn value ->
      byte_size(value) <= 254 and Regex.match?(~r/\A[^@\s<>(),;"]+@[a-zA-Z0-9.-]+\z/u, value)
    end)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp carrier_values({_, address}), do: carrier_values(address)
  defp carrier_values(values) when is_list(values), do: Enum.flat_map(values, &carrier_values/1)
  defp carrier_values(value) when is_binary(value), do: [value]
  defp carrier_values(_), do: []

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
