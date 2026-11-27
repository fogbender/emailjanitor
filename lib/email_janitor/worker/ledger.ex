defmodule EmailJanitor.Worker.Ledger do
  @moduledoc false
  import Ecto.Query
  alias EmailJanitor.Gmail.Ingestion
  alias EmailJanitor.Gmail.Ingestion.{Arrival, Checkpoint}
  alias EmailJanitor.Store.{Action, Scope}
  alias EmailJanitor.Worker.{Deferral, Receipt, Watch, Candidate}

  def install(%Scope{} = scope) do
    case Ingestion.install(scope) do
      result when result in [:ok, :already_up] ->
        case Ecto.Migrator.up(scope.repo, 11, EmailJanitor.Worker.Migration,
               prefix: scope.prefix,
               log: false
             ) do
          result when result in [:ok, :already_up] -> :ok
          other -> other
        end

      other ->
        other
    end
  end

  def action_due(scope, inbox, now) do
    scope.repo.one(
      from(a in Action,
        left_join: r in Receipt,
        on: r.inbox_id == a.inbox_id and r.action_id == a.id,
        where:
          a.inbox_id == ^inbox.id and
            (is_nil(r.action_id) or r.action_updated_at != a.updated_at or
               (r.status == :retry and r.next_attempt_at <= ^now)),
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: 1
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  def receipt(scope, inbox, action, status, now) do
    old =
      scope.repo.get_by(Receipt, [inbox_id: inbox.id, action_id: action.id],
        prefix: scope.prefix,
        log: false
      )

    attempts = if status == :retry, do: min(if(old, do: old.attempts, else: 0) + 1, 16), else: 0
    next = if status == :retry, do: DateTime.add(now, delay(attempts))

    row = %{
      inbox_id: inbox.id,
      action_id: action.id,
      action_updated_at: action.updated_at,
      status: status,
      attempts: attempts,
      next_attempt_at: next,
      inserted_at: now,
      updated_at: now
    }

    scope.repo.insert_all(Receipt, [row],
      prefix: scope.prefix,
      log: false,
      conflict_target: [:inbox_id, :action_id],
      on_conflict:
        {:replace, [:action_updated_at, :status, :attempts, :next_attempt_at, :updated_at]}
    )

    :ok
  end

  def arrival_due(scope, inbox, %Checkpoint{} = checkpoint, version, now) do
    scope.repo.one(
      from(a in Arrival,
        left_join: d in Deferral,
        on:
          d.inbox_id == a.inbox_id and d.generation == a.generation and
            fragment("? = ANY(?)", a.message_id, d.message_ids) and
            d.instruction_version == ^version and
            d.next_attempt_at > ^now,
        where:
          a.inbox_id == ^inbox.id and a.generation == ^checkpoint.generation and
            a.status == :pending and is_nil(d.thread_id),
        order_by: [asc: a.inserted_at, asc: a.message_id],
        limit: 1
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  def targets(scope, inbox, generation, ids) do
    scope.repo.all(
      from(a in Arrival,
        where:
          a.inbox_id == ^inbox.id and a.generation == ^generation and a.status == :pending and
            a.message_id in ^ids,
        order_by: [asc: a.inserted_at, asc: a.message_id],
        limit: 5,
        select: a.message_id
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  def deferral(scope, inbox, generation, thread) do
    scope.repo.get_by(Deferral, [inbox_id: inbox.id, generation: generation, thread_id: thread],
      prefix: scope.prefix,
      log: false
    )
  end

  def defer(scope, inbox, generation, thread, fingerprint, version, ids, status, now) do
    old = deferral(scope, inbox, generation, thread)

    unchanged =
      old && old.fingerprint == fingerprint && old.instruction_version == version &&
        old.status == status

    attempts = min(if(unchanged, do: old.attempts, else: 0) + 1, 16)
    seconds = if status in [:unreadable, :blocked], do: 900, else: delay(attempts)

    row = %{
      inbox_id: inbox.id,
      generation: generation,
      thread_id: thread,
      fingerprint: fingerprint,
      instruction_version: version,
      message_ids: Enum.sort(Enum.uniq(ids)),
      status: status,
      attempts: attempts,
      next_attempt_at: DateTime.add(now, seconds),
      inserted_at: now,
      updated_at: now
    }

    scope.repo.insert_all(Deferral, [row],
      prefix: scope.prefix,
      log: false,
      conflict_target: [:inbox_id, :generation, :thread_id],
      on_conflict:
        {:replace,
         [
           :fingerprint,
           :instruction_version,
           :message_ids,
           :status,
           :attempts,
           :next_attempt_at,
           :updated_at
         ]}
    )

    :ok
  end

  def clear_deferral(scope, inbox, generation, thread) do
    scope.repo.delete_all(
      from(d in Deferral,
        where: d.inbox_id == ^inbox.id and d.generation == ^generation and d.thread_id == ^thread
      ),
      prefix: scope.prefix,
      log: false
    )

    :ok
  end

  def watch_due?(scope, inbox, checkpoint, now) do
    case scope.repo.get(Watch, inbox.id, prefix: scope.prefix, log: false) do
      %Watch{generation: generation, renewed_at: at} when generation == checkpoint.generation ->
        DateTime.diff(now, at) >= 43_200 or
          DateTime.diff(checkpoint.watch_expires_at, now) <= 86_400

      _ ->
        true
    end
  end

  def watched(scope, inbox, generation, now) do
    scope.repo.insert_all(Watch, [%{inbox_id: inbox.id, generation: generation, renewed_at: now}],
      prefix: scope.prefix,
      log: false,
      conflict_target: [:inbox_id],
      on_conflict: {:replace, [:generation, :renewed_at]}
    )

    :ok
  end

  def record_candidate(scope, inbox, id, proposal, generation, now, requested \\ false) do
    scope.repo.insert_all(
      Candidate,
      [
        %{
          inbox_id: inbox.id,
          candidate_id: id,
          generation: generation,
          thread_id: proposal.thread_id,
          message_ids: proposal.message_ids,
          status: :pending,
          requested: requested,
          attempts: 0,
          next_attempt_at: nil,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: scope.prefix,
      log: false,
      conflict_target: [:inbox_id, :candidate_id],
      on_conflict: {:replace, [:generation, :thread_id, :message_ids, :status, :updated_at]}
    )

    :ok
  end

  def retire_candidate(scope, inbox, id, ids) do
    case scope.repo.get_by(Candidate, [inbox_id: inbox.id, candidate_id: id],
           prefix: scope.prefix,
           log: false
         ) do
      nil ->
        :ok

      candidate ->
        remaining = candidate.message_ids -- ids

        scope.repo.update!(
          Ecto.Changeset.change(candidate,
            message_ids: remaining,
            status: if(remaining == [], do: :retired, else: :pending),
            requested: remaining != [] and candidate.requested
          ),
          prefix: scope.prefix,
          log: false
        )

        :ok
    end
  end

  def queue_candidate(scope, inbox, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Candidate{status: :pending} = candidate <-
           scope.repo.get_by(
             Candidate,
             [inbox_id: inbox.id, candidate_id: uuid],
             prefix: scope.prefix,
             log: false
           ),
         true <- pending_source?(scope, inbox, candidate) do
      {count, _} =
        scope.repo.update_all(
          from(c in Candidate,
            where: c.inbox_id == ^inbox.id and c.candidate_id == ^uuid and c.status == :pending
          ),
          [set: [requested: true, attempts: 0, next_attempt_at: nil]],
          prefix: scope.prefix,
          log: false
        )

      if count == 1, do: :ok, else: {:error, :ineligible_recheck}
    else
      _ -> {:error, :ineligible_recheck}
    end
  end

  def candidate_due(scope, inbox, now) do
    scope.repo.one(
      from(c in Candidate,
        where:
          c.inbox_id == ^inbox.id and c.status == :pending and c.requested and
            (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now),
        order_by: [asc: c.updated_at, asc: c.candidate_id],
        limit: 1
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  def candidate_available?(scope, inbox, candidate, generation) do
    with %Candidate{status: :pending, requested: true} = fresh <-
           scope.repo.get_by(
             Candidate,
             [inbox_id: inbox.id, candidate_id: candidate.candidate_id],
             prefix: scope.prefix,
             log: false
           ),
         {:ok, %Checkpoint{generation: ^generation, status: :active, address: address}} <-
           Ingestion.checkpoint(scope, inbox.id),
         true <- address == inbox.address and pending_source?(scope, inbox, fresh) do
      :ok
    else
      _ -> {:error, :ineligible_recheck}
    end
  end

  def authorize_candidate(scope, inbox, candidate, proposal, generation) do
    ids = EmailJanitor.Proposal.evaluated_ids(proposal)

    with :ok <- candidate_available?(scope, inbox, candidate, generation),
         %Candidate{} = fresh <-
           scope.repo.get_by(
             Candidate,
             [inbox_id: inbox.id, candidate_id: candidate.candidate_id],
             prefix: scope.prefix,
             log: false
           ),
         true <- proposal.thread_id == fresh.thread_id,
         true <- valid_selection?(proposal.message_ids) and valid_selection?(ids),
         true <-
           Enum.all?(proposal.message_ids, &(&1 in ids)) and
             Enum.all?(ids, &(&1 in fresh.message_ids)) do
      :ok
    else
      _ -> {:error, :ineligible_recheck}
    end
  end

  def queue_backlog(scope, inbox) do
    candidates =
      from(p in Candidate,
        left_join: c in EmailJanitor.Store.Candidate,
        on: c.inbox_id == p.inbox_id and c.id == p.candidate_id,
        left_join: a in Action,
        on: a.inbox_id == p.inbox_id and a.id == p.candidate_id,
        where:
          p.inbox_id == ^inbox.id and p.status == :pending and
            ((not is_nil(c.id) and c.thread_id == p.thread_id) or
               (a.state == :cancelled and is_nil(a.dispatch_started_at) and
                  a.thread_id == p.thread_id)),
        select: p.candidate_id
      )

    {count, _} =
      scope.repo.update_all(
        from(p in Candidate,
          where: p.inbox_id == ^inbox.id and p.candidate_id in subquery(candidates)
        ),
        [set: [requested: true, attempts: 0, next_attempt_at: nil]],
        prefix: scope.prefix,
        log: false
      )

    {:ok, count}
  end

  def finish_candidate(scope, inbox, candidate, result, now) do
    case result do
      status when status in [:retry, :unreadable, :invalid_decision] ->
        attempts = min(candidate.attempts + 1, 16)
        capped = status == :invalid_decision and attempts >= 8

        scope.repo.update_all(
          from(c in Candidate,
            where:
              c.inbox_id == ^inbox.id and c.candidate_id == ^candidate.candidate_id and
                c.status == :pending
          ),
          [
            set: [
              attempts: attempts,
              requested: not capped,
              next_attempt_at:
                DateTime.add(now, if(status == :unreadable, do: 900, else: delay(attempts)))
            ]
          ],
          prefix: scope.prefix,
          log: false
        )

      _ ->
        scope.repo.update_all(
          from(c in Candidate,
            where: c.inbox_id == ^inbox.id and c.candidate_id == ^candidate.candidate_id
          ),
          [set: [requested: false, next_attempt_at: nil]],
          prefix: scope.prefix,
          log: false
        )
    end

    :ok
  end

  defp pending_source?(scope, inbox, candidate) do
    pending =
      scope.repo.get_by(
        EmailJanitor.Store.Candidate,
        [inbox_id: inbox.id, id: candidate.candidate_id],
        prefix: scope.prefix,
        log: false
      )

    action =
      scope.repo.get_by(Action, [inbox_id: inbox.id, id: candidate.candidate_id],
        prefix: scope.prefix,
        log: false
      )

    source =
      cond do
        pending && pending.thread_id == candidate.thread_id ->
          pending.message_ids

        action && action.state == :cancelled && is_nil(action.dispatch_started_at) &&
            action.thread_id == candidate.thread_id ->
          action.message_ids

        true ->
          []
      end

    candidate.message_ids != [] and Enum.all?(candidate.message_ids, &(&1 in source))
  end

  defp valid_selection?(ids),
    do:
      is_list(ids) and length(ids) in 1..5 and
        Enum.all?(ids, &EmailJanitor.Gmail.Parser.valid_id?/1) and Enum.uniq(ids) == ids

  defp delay(attempts), do: min(30 * Integer.pow(2, min(attempts - 1, 5)), 900)
end
