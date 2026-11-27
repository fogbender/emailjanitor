defmodule EmailJanitor.Reconciliation do
  @moduledoc "History-based resolution of ambiguous intents. Current labels alone are never proof."
  alias EmailJanitor.Store.Action

  @doc """
  Events come from an authenticated Gmail adapter that has fetched every page
  since action.history_id. Expired/incomplete history stays unresolved. This is
  a pure decision: retry IDs must still pass a fresh review before any mutation.
  """
  def resolve(%Action{} = action, %{complete?: true, events: events}) when is_list(events) do
    with {:ok, anchor} <- number(action.history_id),
         {:ok, ordered} <- order(events) do
      relevant =
        Enum.filter(ordered, &(&1.number > anchor and &1.message_id in action.message_ids))

      states =
        Enum.reduce(relevant, Map.new(action.message_ids, &{&1, :unseen}), fn event, acc ->
          case {Map.fetch!(acc, event.message_id), event.event} do
            {_, :inbox_removed} ->
              Map.put(acc, event.message_id, :removed)

            {state, :inbox_added} when state in [:removed, :restored] ->
              Map.put(acc, event.message_id, :restored)

            _ ->
              acc
          end
        end)

      {:ok,
       %{
         removed_ids: ids(states, [:removed, :restored]),
         restored_ids: ids(states, [:restored]),
         retry_ids: ids(states, [:unseen])
       }}
    else
      _ -> {:error, :incomplete_history}
    end
  end

  def resolve(%Action{}, _), do: {:error, :incomplete_history}

  defp ids(states, values) do
    states
    |> Enum.filter(fn {_, state} -> state in values end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp order(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      with %{history_id: id, message_id: mid, event: kind} <- event,
           true <- is_binary(mid) and kind in [:inbox_removed, :inbox_added],
           {:ok, n} <- number(id) do
        {:cont, {:ok, [%{number: n, message_id: mid, event: kind} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_history}}
      end
    end)
    |> case do
      {:ok, ordered} -> {:ok, Enum.sort_by(ordered, & &1.number)}
      error -> error
    end
  end

  defp number(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_history}
    end
  end

  defp number(_), do: {:error, :invalid_history}
end
