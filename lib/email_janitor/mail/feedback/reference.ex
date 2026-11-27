defmodule EmailJanitor.Mail.Feedback.Reference do
  @moduledoc "DB-only exact Janitor reply context from authenticated fresh Sent headers. Never call with SMTP routing hints."
  import Ecto.Query
  alias EmailJanitor.Address
  alias EmailJanitor.Mail.{MessageID, Outgoing, RFCMessageID}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def delivery(scope, configured_sender, headers, historical_recipient? \\ fn _, _ -> false end)

  def delivery(%Scope{} = scope, configured_sender, headers, historical_recipient?)
      when is_list(headers) and length(headers) <= 256 and is_function(historical_recipient?, 2) do
    with {:ok, sender} <- Address.normalize(configured_sender),
         {:ok, current} <- ids(header(headers, "in-reply-to"), 1),
         {:ok, history} <- ids(header(headers, "references"), 20) do
      current_ids = ses_ids(current)

      cond do
        current_ids != [] ->
          lookup(scope, sender, current_ids, historical_recipient?)

        true ->
          case ses_ids(history) do
            [] -> {:ok, :none}
            ids -> lookup(scope, sender, ids, historical_recipient?)
          end
      end
    else
      _ -> {:error, :ambiguous_reply_reference}
    end
  rescue
    _ -> {:error, :reply_context_unavailable}
  end

  def delivery(_, _, _, _), do: {:error, :ambiguous_reply_reference}

  defp lookup(scope, sender, ids, historical_recipient?) do
    rows =
      scope.repo.all(
        from(o in Outgoing,
          join: m in Mailbox,
          on: m.id == o.inbox_id,
          where: o.state == :sent and o.sender == ^sender and o.provider_id in ^ids,
          limit: 2,
          select: %{
            inbox_id: o.inbox_id,
            kind: o.kind,
            reference_ids: o.reference_ids,
            recipient: o.recipient,
            current_recipient: m.address
          }
        ),
        prefix: scope.prefix
      )

    case rows do
      [row] ->
        with {:ok, recipient} <- Address.normalize(row.recipient),
             true <- recipient == row.recipient,
             true <-
               recipient == row.current_recipient or
                 historical_recipient?.(row.inbox_id, recipient) == true do
          {:ok, Map.drop(row, [:recipient, :current_recipient])}
        else
          _ -> {:error, :unverified_reply_reference}
        end

      [] ->
        {:error, :unverified_reply_reference}

      _ ->
        {:error, :ambiguous_reply_reference}
    end
  end

  defp ids(nil, _), do: {:ok, []}

  defp ids(value, limit) when is_binary(value) and byte_size(value) <= 8192 do
    values = String.split(value)

    if length(values) in 1..limit do
      Enum.reduce_while(values, {:ok, []}, fn id, {:ok, acc} ->
        case RFCMessageID.canonical(id) do
          {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
          _ -> {:halt, {:error, :invalid_reference}}
        end
      end)
    else
      {:error, :invalid_reference}
    end
  end

  defp ids(_, _), do: {:error, :invalid_reference}

  defp ses_ids(ids),
    do:
      Enum.flat_map(ids, fn id ->
        case MessageID.provider_id(id) do
          {:ok, id} -> [id]
          _ -> []
        end
      end)
      |> Enum.uniq()

  defp header(headers, name) do
    case for {key, value} <- headers, is_binary(key), String.downcase(key) == name, do: value do
      [] -> nil
      [value] -> value
      _ -> :duplicate
    end
  end
end
