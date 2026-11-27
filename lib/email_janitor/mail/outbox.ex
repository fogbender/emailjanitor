defmodule EmailJanitor.Mail.Outbox do
  @moduledoc """
  Metadata-only durable send fence. Rendering and credentials precede dispatch;
  after the fence, every ambiguous outcome stays unresolved and is never resent
  automatically. A crash can therefore omit an email rather than duplicate it.

  The host authorizer must recheck a currently connected inbox. Renderers receive
  typed metadata IDs and regenerate a transient Message; they cannot choose To.
  """
  import Ecto.Query
  alias EmailJanitor.{Address, Inbox, Owner}
  alias EmailJanitor.Mail.{Config, Message, MessageID, Outgoing, SDK}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def enqueue(%Scope{} = scope, inbox_id, kind, reference_ids, dedupe_id)
      when kind in [:digest, :assistant] and is_list(reference_ids) and
             length(reference_ids) in 1..100 do
    with {:ok, dedupe_id} <- Ecto.UUID.cast(dedupe_id),
         {:ok, reference_ids} <- cast_ids(reference_ids),
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

  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        _ -> {:halt, {:error, :invalid_reference}}
      end
    end)
  end

  def get(%Scope{} = scope, id), do: scope.repo.get(Outgoing, id, prefix: scope.prefix)

  @doc "Keep-only self-mail evidence: configured From, current SES Message-ID and confirmed same-inbox sender/recipient record."
  def self_delivery?(%Scope{} = scope, inbox_id, configured_sender, headers)
      when is_list(headers) and length(headers) <= 256 do
    with {:ok, sender} <- Address.normalize(configured_sender),
         [from] <- header_values(headers, "from"),
         {:ok, [^sender]} <- Address.parse(from),
         [rfc_id] <- header_values(headers, "message-id"),
         {:ok, provider_id} <- MessageID.provider_id(rfc_id) do
      case scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix) do
        %Mailbox{address: recipient} ->
          {:ok,
           scope.repo.exists?(
             from(o in Outgoing,
               where:
                 o.inbox_id == ^inbox_id and
                   o.state == :sent and o.provider_id == ^provider_id and o.sender == ^sender and
                   o.recipient == ^recipient
             ),
             prefix: scope.prefix
           )}

        nil ->
          {:ok, false}
      end
    else
      _ -> {:ok, false}
    end
  rescue
    _ -> {:error, :self_mail_unavailable}
  catch
    _, _ -> {:error, :self_mail_unavailable}
  end

  def self_delivery?(_, _, _, _), do: {:ok, false}

  defp header_values(headers, name) do
    for {key, value} <- headers,
        is_binary(key) and is_binary(value),
        String.downcase(key) == name,
        do: value
  end

  def deliver(%Scope{} = scope, id, %Config{} = config, authorize, render, admission \\ fn _ -> :ok end)
      when is_function(authorize, 1) and is_function(render, 1) and is_function(admission, 1) do
    if scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      Owner.run(fn -> do_deliver(scope, id, config, authorize, render, admission) end)
    end
  end

  defp do_deliver(scope, id, config, authorize, render, admission) do
    with %Outgoing{state: :pending} = row <- get(scope, id),
         {:ok, %Inbox{id: inbox_id, address: address} = inbox} <- authorize.(row.inbox_id),
         true <- inbox_id == row.inbox_id,
         %Mailbox{address: ^address} <- scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix),
         {:ok, %Message{} = message} <- render.(row),
         {:ok, prepared} <- SDK.prepare(config),
         :ok <- Owner.dispatch_window(),
         {:ok, :claimed} <- claim_dispatch(scope, row, inbox, authorize, admission) do
      result = Owner.bounded(fn -> SDK.send(config, prepared, inbox, message) end)

      if result == {:error, :dispatch_window_exhausted} do
        # bounded/1 proves the closure never ran; this is not ambiguous SES
        # acceptance. Only this successful claimant can reset its pending fence.
        scope.repo.update_all(
          from(o in Outgoing, where: o.id == ^id and o.state == :dispatching),
          [set: [state: :pending, updated_at: DateTime.utc_now()]],
          prefix: scope.prefix
        )

        {:error, :mail_unavailable}
      else
        {state, provider_id} =
          case result do
            {:ok, provider_id} -> {:sent, provider_id}
            _ -> {:unresolved, nil}
          end

        scope.repo.update_all(
          from(o in Outgoing, where: o.id == ^id and o.state == :dispatching),
          [
            set: [
              state: state,
              provider_id: provider_id,
              sender: if(state == :sent, do: config.sender),
              recipient: if(state == :sent, do: inbox.address),
              updated_at: DateTime.utc_now()
            ]
          ],
          prefix: scope.prefix
        )

        if state == :sent, do: :ok, else: {:error, :unresolved_delivery}
      end
    else
      %Outgoing{state: :sent} -> :ok
      %Outgoing{} -> {:error, :unresolved_delivery}
      {:error, :mail_admission_rejected} -> {:error, :mail_admission_rejected}
      _ -> {:error, :mail_unavailable}
    end
  end

  # Match host settlement/disconnect order: scoped mailbox precedes public host
  # authorization locks and outgoing state. The authorizer is DB-only here.
  defp claim_dispatch(scope, row, inbox, authorize, admission) do
    scope.repo.transaction(fn ->
      mailbox =
        scope.repo.one(from(m in Mailbox, where: m.id == ^row.inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      if is_nil(mailbox) or mailbox.address != inbox.address,
        do: scope.repo.rollback(:mail_unavailable)

      if authorize.(row.inbox_id) != {:ok, inbox}, do: scope.repo.rollback(:mail_unavailable)
      current = scope.repo.one(from(o in Outgoing, where: o.id == ^row.id and o.state == :pending, lock: "FOR UPDATE"), prefix: scope.prefix)
      if is_nil(current), do: scope.repo.rollback(:already_dispatched)
      if admission.(current) != :ok, do: scope.repo.rollback(:mail_admission_rejected)

      case scope.repo.update_all(
             from(o in Outgoing, where: o.id == ^row.id and o.state == :pending),
             [set: [state: :dispatching, updated_at: DateTime.utc_now()]],
             prefix: scope.prefix
           ) do
        {1, _} -> :claimed
        _ -> scope.repo.rollback(:already_dispatched)
      end
    end)
  end
end
