defmodule EmailJanitor.Mail.Outbox do
  @moduledoc """
  Metadata-only durable send fence. Rendering and credentials precede dispatch;
  after the fence, every ambiguous outcome stays unresolved and is never resent
  automatically. A crash can therefore omit an email rather than duplicate it.

  The host authorizer must recheck a currently connected inbox. Renderers receive
  typed metadata IDs and regenerate a transient Message; they cannot choose To.
  """
  import Ecto.Query
  alias EmailJanitor.{Inbox, Owner}
  alias EmailJanitor.Mail.{Config, Message, Outgoing, SDK}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def enqueue(%Scope{} = scope, inbox_id, kind, reference_ids, dedupe_id)
      when kind in [:digest, :assistant] and is_list(reference_ids) and
             length(reference_ids) in 1..100 do
    with {:ok, dedupe_id} <- Ecto.UUID.cast(dedupe_id),
         true <- Enum.all?(reference_ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
         %Mailbox{} <- scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix) do
      row = %Outgoing{
        inbox_id: inbox_id,
        kind: kind,
        reference_ids: reference_ids,
        dedupe_id: dedupe_id
      }

      scope.repo.insert!(row,
        prefix: scope.prefix,
        on_conflict: :nothing,
        conflict_target: [:inbox_id, :kind, :dedupe_id]
      )

      saved =
        scope.repo.get_by!(Outgoing, [inbox_id: inbox_id, kind: kind, dedupe_id: dedupe_id],
          prefix: scope.prefix
        )

      if saved.reference_ids == reference_ids,
        do: {:ok, saved},
        else: {:error, :outbox_reference_conflict}
    else
      _ -> {:error, :invalid_outbox_intent}
    end
  end

  def enqueue(_, _, _, _, _), do: {:error, :invalid_outbox_intent}

  def get(%Scope{} = scope, id), do: scope.repo.get(Outgoing, id, prefix: scope.prefix)

  def deliver(%Scope{} = scope, id, %Config{} = config, authorize, render)
      when is_function(authorize, 1) and is_function(render, 1) do
    if scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      Owner.run(fn -> do_deliver(scope, id, config, authorize, render) end)
    end
  end

  defp do_deliver(scope, id, config, authorize, render) do
    with %Outgoing{state: :pending} = row <- get(scope, id),
         {:ok, %Inbox{id: inbox_id, address: address} = inbox} <- authorize.(row.inbox_id),
         true <- inbox_id == row.inbox_id,
         %Mailbox{address: ^address} <- scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix),
         {:ok, %Message{} = message} <- render.(row),
         {:ok, prepared} <- SDK.prepare(config),
         # Recheck connection after rendering/credential resolution, before the
         # committed fence. No SQL transaction may contain a provider call.
         {:ok, ^inbox} <- authorize.(row.inbox_id),
         :ok <- Owner.dispatch_window(),
         {1, _} <-
           scope.repo.update_all(
             from(o in Outgoing, where: o.id == ^id and o.state == :pending),
             [set: [state: :dispatching, updated_at: DateTime.utc_now()]],
             prefix: scope.prefix
           ) do
      result = Owner.bounded(fn -> SDK.send(config, prepared, inbox, message) end)

      {state, provider_id} =
        case result do
          {:ok, provider_id} -> {:sent, provider_id}
          _ -> {:unresolved, nil}
        end

      scope.repo.update_all(
        from(o in Outgoing, where: o.id == ^id and o.state == :dispatching),
        [set: [state: state, provider_id: provider_id, updated_at: DateTime.utc_now()]],
        prefix: scope.prefix
      )

      if state == :sent, do: :ok, else: {:error, :unresolved_delivery}
    else
      %Outgoing{state: :sent} -> :ok
      %Outgoing{} -> {:error, :unresolved_delivery}
      _ -> {:error, :mail_unavailable}
    end
  end
end
