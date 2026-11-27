defmodule EmailJanitor.Conversation.Reference do
  @moduledoc "A host-resolved, inbox-bound email reference; sender and subject are transient metadata."
  alias EmailJanitor.Content
  alias EmailJanitor.Gmail.Parser
  @derive {Inspect, only: [:token, :inbox_id, :message_id, :thread_id, :action_id]}
  @enforce_keys [:token, :inbox_id, :message_id, :thread_id, :sender, :subject]
  defstruct @enforce_keys ++ [:action_id]

  def new(inbox_id, message_id, thread_id, sender, subject, opts \\ []) do
    action_id = opts[:action_id]

    with true <- is_binary(inbox_id) and inbox_id != "",
         true <- Parser.valid_id?(message_id) and Parser.valid_id?(thread_id),
         true <- is_nil(action_id) or match?({:ok, _}, Ecto.UUID.cast(action_id)),
         true <- text?(sender, 512) and text?(subject, 1024) do
      {:ok,
       %__MODULE__{
         token:
           "ref_" <>
             Base.url_encode64(:crypto.hash(:sha256, inbox_id <> ":" <> message_id),
               padding: false
             ),
         inbox_id: inbox_id,
         message_id: message_id,
         thread_id: thread_id,
         action_id: action_id,
         sender: Content.new(sender),
         subject: Content.new(subject)
       }}
    else
      _ -> {:error, :invalid_reference}
    end
  end

  defp text?(text, max) do
    is_binary(text) and byte_size(text) <= max and String.valid?(text) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, text)
  end
end
