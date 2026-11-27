defmodule EmailJanitor.TargetDecisions do
  @moduledoc "One bounded model response must account for every selected target, and no context IDs."
  alias EmailJanitor.Decision

  def schema do
    item = Decision.schema()

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["decisions"],
      "properties" => %{
        "decisions" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 5,
          "items" => %{
            item
            | "required" => ["message_id" | item["required"]],
              "properties" => Map.put(item["properties"], "message_id", %{"type" => "string"})
          }
        }
      }
    }
  end

  def parse(json, ids) when is_binary(json) and byte_size(json) <= 16_384 do
    with {:ok, object} <- Jason.decode(json) do
      parse(object, ids)
    else
      _ -> {:error, :invalid_decision}
    end
  rescue
    _ -> {:error, :invalid_decision}
  end

  def parse(%{"decisions" => entries} = object, ids)
      when map_size(object) == 1 and is_list(entries) and length(entries) in 1..5 and is_list(ids) do
    with true <- length(entries) == length(ids),
         {:ok, decisions} <- parse_entries(entries),
         true <- Enum.sort(Map.keys(decisions)) == Enum.sort(ids) do
      {:ok, decisions}
    else
      _ -> {:error, :invalid_decision}
    end
  end

  def parse(_, _), do: {:error, :invalid_decision}

  defp parse_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{"message_id" => id} = entry, {:ok, acc}
      when map_size(entry) == 4 and is_binary(id) ->
        case Decision.parse(Map.delete(entry, "message_id")) do
          {:ok, decision} when not is_map_key(acc, id) ->
            {:cont, {:ok, Map.put(acc, id, decision)}}

          _ ->
            {:halt, {:error, :invalid_decision}}
        end

      _, _ ->
        {:halt, {:error, :invalid_decision}}
    end)
  end
end
