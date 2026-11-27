defmodule EmailJanitor.SelfHost.ActivityPolicy do
  @moduledoc "Unlimited self-host admission with minimal crash-safe daily-report metadata."
  @behaviour EmailJanitor.Policy
  alias EmailJanitor.{Content, Digest, Message, Policy, SelfHost}
  alias EmailJanitor.Conversation.Reference
  alias EmailJanitor.Digest.Event
  alias EmailJanitor.SelfHost.Store

  def for_messages(ref, inbox, messages) when is_list(messages) do
    values =
      Enum.map(messages, fn %Message{id: id, headers: headers} ->
        {id, header(headers, "from"), header(headers, "subject")}
      end)

    build(ref, inbox, values)
  rescue
    _ -> {:error, :policy_unavailable}
  end

  def for_references(ref, inbox, references) when is_list(references) do
    values =
      Enum.map(references, fn %Reference{
                                inbox_id: id,
                                message_id: message,
                                sender: %Content{} = sender,
                                subject: %Content{} = subject
                              }
                              when id == inbox.id ->
        {message, Content.read(sender), Content.read(subject)}
      end)

    build(ref, inbox, values)
  rescue
    _ -> {:error, :policy_unavailable}
  end

  def settlement(ref, inbox),
    do: %Policy{adapter: __MODULE__, context: %{ref: ref, inbox: inbox, metadata: %{}}}

  defp build(ref, inbox, values) do
    with true <- length(values) <= 1000,
         ids <- Enum.map(values, &elem(&1, 0)),
         true <- length(Enum.uniq(ids)) == length(ids),
         metadata when is_map(metadata) <-
           Enum.reduce(values, %{}, fn {id, sender, subject}, acc ->
             case Event.new(Ecto.UUID.generate(), id, :done, sender, subject, DateTime.utc_now()) do
               {:ok, event} -> Map.put(acc, id, %{sender: event.sender, subject: event.subject})
               _ -> acc
             end
           end) do
      {:ok, %Policy{adapter: __MODULE__, context: %{ref: ref, inbox: inbox, metadata: metadata}}}
    else
      _ -> {:error, :policy_unavailable}
    end
  end

  def reserve(context, inbox, action, ids, now),
    do: reserve(context, inbox, action, ids, now, nil)

  def reserve(context, inbox, action, ids, now, _admission) do
    with true <- context.inbox.id == inbox,
         :ok <- Store.guard(context.ref, context.inbox) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        with %{sender: sender, subject: subject} <- Map.get(context.metadata, id),
             {:ok, event} <- Event.new(action, id, :done, sender, subject, now),
             :ok <- Digest.stage(SelfHost.scope(), inbox, event) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, :policy_unavailable}}
        end
      end)
    else
      _ -> {:error, :connection_changed}
    end
  end

  # Settlement intentionally needs neither credentials nor a currently connected
  # binding: the core's durable applied IDs are sufficient after disconnect.
  def settle(_context, inbox, action, _result),
    do: Digest.confirm_staged(SelfHost.scope(), inbox, action)

  # Restore calls this base policy outside Worker.Gate. Keep its provenance IDs
  # synchronized under the core caller's existing mailbox transaction. The
  # Gate's second forwarding is intentionally harmless and never widens IDs.
  def retire_candidate(context, inbox, candidate, ids),
    do: retire_candidate_messages(context, inbox, candidate, ids)

  def retire_candidate_messages(context, inbox, candidate, ids) do
    scope = SelfHost.scope()

    if context.inbox.id == inbox and scope.repo.in_transaction?() do
      EmailJanitor.Worker.Ledger.retire_candidate(scope, context.inbox, candidate, ids)
    else
      {:error, :policy_unavailable}
    end
  end

  defp header(headers, name),
    do:
      Enum.find_value(headers, "", fn
        {key, value} when is_binary(key) and is_binary(value) ->
          if String.downcase(key) == name, do: value

        _ ->
          nil
      end)
end
