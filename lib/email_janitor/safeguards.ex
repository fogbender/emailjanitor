defmodule EmailJanitor.Safeguards do
  @moduledoc "Deterministic protections applied before classification and again before Gmail mutation."
  alias EmailJanitor.{Identity, Message}

  def evaluate(messages, inbox, contacted_keys, restored_ids \\ MapSet.new()) do
    cond do
      messages == [] ->
        {:keep, :empty_thread}

      Enum.any?(messages, &Enum.any?(&1.labels, fn l -> l in ["SENT", "DRAFT"] end)) ->
        {:keep, :sent_or_draft}

      Enum.any?(messages, &MapSet.member?(restored_ids, &1.id)) ->
        {:keep, :manually_restored}

      true ->
        identities(messages, inbox, contacted_keys)
    end
  end

  defp identities(messages, inbox, contacted_keys) do
    Enum.reduce_while(messages, {:classify, MapSet.new()}, fn %Message{} = message,
                                                              {:classify, acc} ->
      case Identity.resolve(message, inbox) do
        {:ok, keys} ->
          if Enum.any?(keys, &MapSet.member?(contacted_keys, &1)) do
            {:halt, {:keep, :prior_correspondence}}
          else
            {:cont, {:classify, MapSet.union(acc, MapSet.new(keys))}}
          end

        {:keep, reason} ->
          {:halt, {:keep, reason}}

        {:error, _} ->
          {:halt, {:keep, :unknown_sender}}
      end
    end)
  end
end
