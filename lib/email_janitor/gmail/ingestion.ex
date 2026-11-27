defmodule EmailJanitor.Gmail.Ingestion do
  @moduledoc """
  Durable new-arrival discovery, without classification or Gmail mutations.

  Only IDs, cursors, identities and timestamps persist. First connection and an
  explicit reconnect establish a new watch baseline; a restart resumes its old
  cursor. Complete history and discovered IDs commit together. Expired history
  pauses ingestion in :gap; rebaselining does NOT recover that missed backlog.
  OAuth refresh/reconsent is credential recovery and must resume the existing
  checkpoint; only deliberate disconnect plus a new connection may reset it.
  """
  import Ecto.Query
  alias EmailJanitor.{Inbox, Message, Proposal, Store}

  alias EmailJanitor.Gmail.{
    Parser,
    HistoryBatch,
    Ingestion.Arrival,
    Ingestion.Checkpoint,
    Ingestion.Migration
  }

  @provider_errors [:authorization_required, :forbidden, :rate_limited, :wrong_inbox]
  alias EmailJanitor.Store.{Mailbox, Scope}

  defmodule Eligible do
    @moduledoc "Metadata-only eligibility boundary; hosts must recheck it before execution."
    @enforce_keys [:inbox_id, :generation, :thread_id, :message_ids]
    defstruct @enforce_keys
  end

  def install(%Scope{} = scope) do
    Store.install(scope)
    Ecto.Migrator.up(scope.repo, 10, Migration, prefix: scope.prefix, log: false)
  end

  def checkpoint(%Scope{} = scope, inbox_id) do
    protect(fn ->
      case scope.repo.get(Checkpoint, inbox_id, prefix: scope.prefix, log: false) do
        nil -> {:error, :not_initialized}
        checkpoint -> {:ok, checkpoint}
      end
    end)
  end

  @doc "Seed an initial connection from its watch response, never from an INBOX scan."
  def baseline(%Scope{} = scope, %Inbox{} = inbox, watch), do: establish(scope, inbox, nil, watch)

  @doc "Deliberate disconnect+reconnect only: reset eligibility; never use for OAuth reconsent or refresh."
  def reconnect(%Scope{} = scope, %Inbox{} = inbox, generation, watch) when is_binary(generation),
    do: establish(scope, inbox, generation, watch)

  defp establish(scope, inbox, expected, %{history_id: id, expires_at: %DateTime{} = expiry}) do
    protect(fn ->
      with true <- history_id?(id) and DateTime.compare(expiry, DateTime.utc_now()) == :gt do
        transaction(scope, fn ->
          registered =
            scope.repo.one(
              from(m in Mailbox, where: m.id == ^inbox.id, lock: "FOR NO KEY UPDATE"),
              prefix: scope.prefix,
              log: false
            )

          require!(
            scope,
            match?(%Mailbox{address: address} when address == inbox.address, registered),
            :wrong_inbox
          )

          current = locked(scope, inbox.id)

          require!(
            scope,
            if(is_nil(expected),
              do: is_nil(current),
              else: match?(%Checkpoint{generation: ^expected}, current)
            ),
            :generation_changed
          )

          now = DateTime.utc_now()

          values = %{
            inbox_id: inbox.id,
            address: inbox.address,
            generation: Ecto.UUID.generate(),
            generation_started_at: now,
            baseline_id: id,
            cursor: id,
            requested_id: nil,
            watch_expires_at: utc(expiry),
            status: :active
          }

          scope.repo.delete_all(from(a in Arrival, where: a.inbox_id == ^inbox.id),
            prefix: scope.prefix,
            log: false
          )

          if current do
            scope.repo.update!(Ecto.Changeset.change(current, Map.delete(values, :inbox_id)),
              prefix: scope.prefix,
              log: false
            )
          else
            scope.repo.insert!(struct!(Checkpoint, values), prefix: scope.prefix, log: false)
          end
        end)
      else
        _ -> {:error, :invalid_watch}
      end
    end)
  end

  defp establish(_, _, _, _), do: {:error, :invalid_watch}

  @doc "Commit a coalesced wake-up hint before acknowledging a pulled delivery."
  def record_signal(%Scope{} = scope, %Inbox{} = inbox, hint) do
    protect(fn ->
      if history_id?(hint) do
        transaction(scope, fn ->
          current = present!(scope, inbox)

          requested =
            if newer?(hint, current.cursor) and
                 (is_nil(current.requested_id) or newer?(hint, current.requested_id)),
               do: hint,
               else: current.requested_id

          scope.repo.update!(Ecto.Changeset.change(current, requested_id: requested),
            prefix: scope.prefix,
            log: false
          )

          :ok
        end)
      else
        {:error, :invalid_history_id}
      end
    end)
  end

  @doc "Fetch a bounded closed-record history batch, then commit its IDs and cursor together."
  def catch_up(%Scope{} = scope, %Inbox{} = inbox, {gmail, options}) do
    protect(fn ->
      with {:ok, %Checkpoint{status: :active, address: address} = previous} <-
             checkpoint(scope, inbox.id),
           true <- address == inbox.address do
        case gmail.ingestion_batch(inbox.id, previous.cursor, options) do
          {:ok, %HistoryBatch{} = history} -> persist_history(scope, inbox, previous, history)
          {:error, :history_expired} -> mark_gap(scope, inbox, previous)
          {:error, reason} = error when reason in @provider_errors -> error
          {:error, reason} = error when reason in [:incomplete_history, :invalid_history] -> error
          _ -> {:error, :gmail_unavailable}
        end
      else
        {:ok, %Checkpoint{status: :gap}} -> {:error, :history_gap}
        {:error, _} = error -> error
        _ -> {:error, :wrong_inbox}
      end
    end)
  end

  defp persist_history(scope, inbox, previous, history) do
    with true <- valid_history?(history, previous) do
      transaction(scope, fn ->
        current = unchanged!(scope, inbox, previous)
        now = DateTime.utc_now()

        rows =
          Enum.map(Enum.uniq(history.added_message_ids), fn id ->
            %{
              inbox_id: inbox.id,
              generation: current.generation,
              message_id: id,
              observed_history_id: history.through_id,
              status: :pending,
              inserted_at: now,
              updated_at: now
            }
          end)

        discovered =
          Enum.chunk_every(rows, 500)
          |> Enum.reduce(0, fn chunk, total ->
            {count, _} =
              scope.repo.insert_all(Arrival, chunk,
                on_conflict: :nothing,
                conflict_target: [:inbox_id, :generation, :message_id],
                prefix: scope.prefix,
                log: false
              )

            total + count
          end)

        requested =
          if current.requested_id && newer?(current.requested_id, history.through_id),
            do: current.requested_id

        scope.repo.update!(
          Ecto.Changeset.change(current, cursor: history.through_id, requested_id: requested),
          prefix: scope.prefix,
          log: false
        )

        %{cursor: history.through_id, discovered_count: discovered, more?: history.more?}
      end)
    else
      _ -> {:error, :invalid_history}
    end
  end

  defp mark_gap(scope, inbox, previous) do
    case transaction(scope, fn ->
           current = unchanged!(scope, inbox, previous)

           scope.repo.update!(Ecto.Changeset.change(current, status: :gap),
             prefix: scope.prefix,
             log: false
           )
         end) do
      {:ok, _} -> {:error, :history_gap}
      error -> error
    end
  end

  @doc "Renew a watch without changing its durable baseline, processing cursor or pending signals."
  def renew_watch(%Scope{} = scope, %Inbox{} = inbox, topic, {gmail, options}) do
    protect(fn ->
      with {:ok, %Checkpoint{status: :active, address: address} = previous} <-
             checkpoint(scope, inbox.id),
           true <- address == inbox.address,
           {:ok, %{history_id: id, expires_at: %DateTime{} = expires}} <-
             gmail.renew_watch(inbox.id, topic, options),
           true <- history_id?(id) and DateTime.compare(expires, DateTime.utc_now()) == :gt do
        transaction(scope, fn ->
          current = active!(scope, inbox)
          require!(scope, current.generation == previous.generation, :generation_changed)

          scope.repo.update!(Ecto.Changeset.change(current, watch_expires_at: utc(expires)),
            prefix: scope.prefix,
            log: false
          )
        end)
      else
        {:error, reason} = error when reason in @provider_errors -> error
        _ -> {:error, :watch_unavailable}
      end
    end)
  end

  def pending(%Scope{} = scope, %Inbox{} = inbox, limit \\ 100) do
    protect(fn ->
      with true <- is_integer(limit) and limit in 1..1000,
           {:ok, %Checkpoint{status: :active, address: address} = current} <-
             checkpoint(scope, inbox.id),
           true <- address == inbox.address do
        {:ok,
         scope.repo.all(
           from(a in Arrival,
             where:
               a.inbox_id == ^inbox.id and a.generation == ^current.generation and
                 a.status == :pending,
             order_by: [asc: a.inserted_at, asc: a.message_id],
             limit: ^limit
           ),
           prefix: scope.prefix,
           log: false
         )}
      else
        {:ok, %Checkpoint{status: :gap}} -> {:error, :history_gap}
        {:error, _} = error -> error
        _ -> {:error, :invalid_request}
      end
    end)
  end

  def mark_processed(%Scope{} = scope, %Inbox{} = inbox, generation, ids) do
    protect(fn ->
      with true <- valid_ids?(ids, 1000) do
        transaction(scope, fn ->
          current = active!(scope, inbox)
          require!(scope, current.generation == generation, :generation_changed)
          known = known_ids(scope, inbox.id, generation, ids)
          require!(scope, MapSet.size(known) == length(Enum.uniq(ids)), :unknown_arrival)

          scope.repo.update_all(
            from(a in Arrival,
              where:
                a.inbox_id == ^inbox.id and a.generation == ^generation and a.message_id in ^ids
            ),
            [set: [status: :processed, updated_at: DateTime.utc_now()]],
            prefix: scope.prefix,
            log: false
          )

          :ok
        end)
      else
        _ -> {:error, :invalid_request}
      end
    end)
  end

  @doc "Preserve a whole thread if ANY current INBOX message lacks durable post-baseline eligibility."
  def eligible_thread(
        %Scope{} = scope,
        %Inbox{} = inbox,
        generation,
        message_id,
        {gmail, options}
      ) do
    protect(fn ->
      with true <- Parser.valid_id?(message_id),
           {:ok, %Checkpoint{status: :active, generation: ^generation, address: address}} <-
             checkpoint(scope, inbox.id),
           true <- address == inbox.address,
           true <-
             MapSet.member?(known_ids(scope, inbox.id, generation, [message_id]), message_id),
           {:ok, thread_id} <- gmail.thread_id(inbox.id, message_id, options),
           true <- Parser.valid_id?(thread_id),
           {:ok, messages} <- gmail.thread(inbox.id, thread_id, options),
           true <- valid_messages?(messages, thread_id) do
        ids = messages |> Enum.filter(&Message.in_inbox?/1) |> Enum.map(& &1.id) |> Enum.sort()
        known = known_ids(scope, inbox.id, generation, ids)

        cond do
          ids == [] ->
            {:skip, :not_in_inbox}

          Enum.any?(ids, &(not MapSet.member?(known, &1))) ->
            {:skip, :prebaseline_inbox}

          true ->
            {:ok,
             %Eligible{
               inbox_id: inbox.id,
               generation: generation,
               thread_id: thread_id,
               message_ids: ids
             }}
        end
      else
        {:error, :not_found} -> {:skip, :deleted_arrival}
        {:error, reason} = error when reason in @provider_errors -> error
        _ -> {:error, :eligibility_unavailable}
      end
    end)
  end

  @doc "Host pre-execution check; it does not replace Executor freshness or host connection-generation fencing."
  def authorize_proposal(
        %Scope{} = scope,
        %Inbox{} = inbox,
        %Eligible{} = eligible,
        %Proposal{} = proposal
      ) do
    protect(fn ->
      with true <- eligible.inbox_id == inbox.id and eligible.thread_id == proposal.thread_id,
           true <- proposal.message_ids != [] and valid_ids?(proposal.message_ids, 1000),
           true <- length(Enum.uniq(proposal.message_ids)) == length(proposal.message_ids),
           {:ok, %Checkpoint{status: :active, generation: generation, address: address}} <-
             checkpoint(scope, inbox.id),
           true <- address == inbox.address,
           true <- generation == eligible.generation,
           known = known_ids(scope, inbox.id, generation, proposal.message_ids),
           true <-
             Enum.all?(
               proposal.message_ids,
               &(&1 in eligible.message_ids and MapSet.member?(known, &1))
             ) do
        :ok
      else
        _ -> {:error, :ineligible_proposal}
      end
    end)
  end

  defp valid_history?(
         %HistoryBatch{
           from_id: from,
           through_id: id,
           more?: more,
           added_message_ids: ids,
           started_at: %DateTime{} = started
         },
         previous
       ) do
    from == previous.cursor and is_boolean(more) and history_id?(id) and
      not newer?(previous.cursor, id) and
      (not more or newer?(id, previous.cursor)) and valid_ids?(ids, 1_000_000) and
      DateTime.compare(started, previous.generation_started_at) in [:eq, :gt]
  end

  defp valid_history?(_, _), do: false

  defp valid_ids?(ids, max),
    do: is_list(ids) and length(ids) <= max and Enum.all?(ids, &Parser.valid_id?/1)

  defp valid_messages?(messages, thread),
    do:
      is_list(messages) and messages != [] and length(messages) <= 200 and
        Enum.all?(messages, &match?(%Message{thread_id: ^thread}, &1)) and
        Enum.all?(messages, &Parser.valid_id?(&1.id)) and
        length(Enum.uniq_by(messages, & &1.id)) == length(messages)

  defp history_id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9]{1,32}\z/, value)
  defp newer?(left, right), do: String.to_integer(left) > String.to_integer(right)

  defp utc(value),
    do: value |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)

  defp known_ids(scope, inbox, generation, ids) do
    scope.repo.all(
      from(a in Arrival,
        where: a.inbox_id == ^inbox and a.generation == ^generation and a.message_id in ^ids,
        select: a.message_id
      ),
      prefix: scope.prefix,
      log: false
    )
    |> MapSet.new()
  end

  defp locked(scope, inbox),
    do:
      scope.repo.one(from(c in Checkpoint, where: c.inbox_id == ^inbox, lock: "FOR UPDATE"),
        prefix: scope.prefix,
        log: false
      )

  defp active!(scope, inbox) do
    current = present!(scope, inbox)
    require!(scope, current.status == :active, :history_gap)
    current
  end

  defp present!(scope, inbox) do
    current = locked(scope, inbox.id)
    require!(scope, match?(%Checkpoint{}, current), :not_initialized)
    require!(scope, current.address == inbox.address, :wrong_inbox)
    current
  end

  defp unchanged!(scope, inbox, previous) do
    current = active!(scope, inbox)

    require!(
      scope,
      current.generation == previous.generation and current.cursor == previous.cursor,
      :cursor_changed
    )

    current
  end

  defp require!(_, true, _), do: :ok
  defp require!(scope, false, reason), do: scope.repo.rollback(reason)

  defp transaction(scope, operation) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: scope.repo.transaction(operation, log: false)
  end

  defp protect(operation) do
    case operation.() do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, reason} = result when is_atom(reason) -> result
      {:skip, reason} = result when is_atom(reason) -> result
      _ -> {:error, :ingestion_unavailable}
    end
  rescue
    _ -> {:error, :ingestion_unavailable}
  catch
    _, _ -> {:error, :ingestion_unavailable}
  end
end
