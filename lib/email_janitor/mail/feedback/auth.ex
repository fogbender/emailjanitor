defmodule EmailJanitor.Mail.Feedback.Auth do
  @moduledoc "A fresh current Sent copy is the only source of an authenticated email command."
  alias EmailJanitor.{Address, Inbox, Message}
  alias EmailJanitor.Mail.RFCMessageID

  def verify(
        %Message{} = message,
        %Inbox{} = sender_inbox,
        rfc_id,
        janitor,
        %DateTime{} = received_at
      ) do
    with true <-
           "SENT" in message.labels and
             Enum.all?(~w(DRAFT TRASH SPAM), &(&1 not in message.labels)),
         {:ok, ^rfc_id} <- RFCMessageID.canonical(Message.header(message, "message-id")),
         {:ok, [from]} <- Address.parse(Message.header(message, "from")),
         true <- from == sender_inbox.address,
         {:ok, recipients} <- recipients(message),
         true <- janitor in recipients,
         %DateTime{} = sent_at <- message.received_at,
         delta = DateTime.diff(received_at, sent_at, :microsecond),
         true <- delta >= -300_000_000 and delta <= 3_600_000_000 do
      :ok
    else
      _ -> {:error, :unverified_sent_copy}
    end
  rescue
    _ -> {:error, :unverified_sent_copy}
  end

  def verify(_, _, _, _, _), do: {:error, :unverified_sent_copy}

  defp recipients(message) do
    Enum.reduce_while(~w(to cc bcc), {:ok, []}, fn name, {:ok, acc} ->
      case Message.header(message, name) do
        value when value in [nil, ""] ->
          {:cont, {:ok, acc}}

        value ->
          case Address.parse(value) do
            {:ok, addresses} -> {:cont, {:ok, addresses ++ acc}}
            _ -> {:halt, {:error, :invalid_recipient}}
          end
      end
    end)
  end
end
