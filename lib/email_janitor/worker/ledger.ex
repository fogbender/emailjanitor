defmodule EmailJanitor.Worker.Ledger do
  @moduledoc false
  import Ecto.Query
  alias EmailJanitor.Gmail.Ingestion
  alias EmailJanitor.Gmail.Ingestion.Checkpoint
  alias EmailJanitor.Store.{Action, Mailbox, Scope}
  alias EmailJanitor.Worker.{Arrival, Deferral, Receipt, Watch, Candidate, ModelStreak}

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
        order_by: [asc_nulls_first: a.last_attempt_at, asc: a.inserted_at, asc: a.message_id],
        limit: 1
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  def attempted(scope, inbox, generation, id, now) do
    scope.repo.update_all(
      from(a in Arrival,
        where:
          a.inbox_id == ^inbox.id and
            a.generation == ^generation and a.message_id == ^id and a.status == :pending
      ),
      [set: [last_attempt_at: now]],
      prefix: scope.prefix,
      log: false
    )

    :ok
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

  def record_candidate(
        scope,
        inbox,
        id,
        proposal,
        generation,
        now,
        requested \\ false,
        source \\ nil
      ) do
    scope.repo.insert_all(
      Candidate,
      [
        %{
          inbox_id: inbox.id,
          candidate_id: id,
          generation: generation,
          thread_id: proposal.thread_id,
          message_ids: proposal.message_ids,
          source_kind: if(source, do: source.source_kind, else: :arrival),
          authority_id: if(source, do: source.authority_id, else: nil),
          status: :pending,
          requested: requested,
          attempts: 0,
          invalid_attempts: 0,
          next_attempt_at: nil,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: scope.prefix,
      log: false,
      conflict_target: [:inbox_id, :candidate_id],
      on_conflict:
        {:replace,
         [
           :generation,
           :thread_id,
           :message_ids,
           :source_kind,
           :authority_id,
           :status,
           :updated_at
         ]}
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
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      case scope.repo.transaction(fn ->
             mailbox =
               scope.repo.one(from(m in Mailbox, where: m.id == ^inbox.id, lock: "FOR UPDATE"),
                 prefix: scope.prefix,
                 log: false
               )

             unless mailbox && mailbox.address == inbox.address,
               do: scope.repo.rollback(:ineligible_recheck)

             candidate =
               scope.repo.one(
                 from(c in Candidate,
                   where:
                     c.inbox_id == ^inbox.id and c.candidate_id == ^uuid and c.status == :pending,
                   lock: "FOR UPDATE"
                 ),
                 prefix: scope.prefix,
                 log: false
               )

             unless candidate && pending_source?(scope, inbox, candidate),
               do: scope.repo.rollback(:ineligible_recheck)

             :ok = EmailJanitor.Store.fence_recheck(scope, inbox.id, candidate.message_ids)

             scope.repo.update_all(
               from(c in Candidate,
                 where:
                   c.inbox_id == ^inbox.id and c.candidate_id == ^uuid and c.status == :pending
               ),
               [
                 set: [
                   requested: true,
                   attempts: 0,
                   invalid_attempts: 0,
                   rejected_attempts: 0,
                   contract_blocked: false,
                   next_attempt_at: nil
                 ],
                 inc: [request_version: 1]
               ],
               prefix: scope.prefix,
               log: false
             )

             :ok
           end) do
        {:ok, :ok} -> :ok
        _ -> {:error, :ineligible_recheck}
      end
    else
      _ -> {:error, :ineligible_recheck}
    end
  end

  def queue_manual(scope, inbox, id, thread, ids, options) do
    authority = Keyword.get(options, :authority_id, id)

    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, authority} <- Ecto.UUID.cast(authority),
         true <- EmailJanitor.Gmail.Parser.valid_id?(thread) and valid_selection?(ids) do
      case scope.repo.transaction(fn ->
             mailbox =
               scope.repo.one(
                 from(m in Mailbox,
                   where: m.id == ^inbox.id,
                   lock: "FOR NO KEY UPDATE"
                 ),
                 prefix: scope.prefix,
                 log: false
               )

             if is_nil(mailbox) or mailbox.address != inbox.address,
               do: scope.repo.rollback(:ineligible_recheck)

             checkpoint =
               case Ingestion.checkpoint(scope, inbox.id) do
                 {:ok, %{status: :active, address: address} = cp} when address == inbox.address ->
                   cp

                 _ ->
                   scope.repo.rollback(:ineligible_recheck)
               end

             source = %Candidate{
               inbox_id: inbox.id,
               candidate_id: id,
               thread_id: thread,
               message_ids: Enum.sort(ids),
               status: :pending,
               source_kind: :manual,
               authority_id: authority
             }

             if not pending_source?(scope, inbox, source),
               do: scope.repo.rollback(:ineligible_recheck)

             existing =
               scope.repo.one(
                 from(c in Candidate,
                   where: c.inbox_id == ^inbox.id and c.candidate_id == ^id,
                   lock: "FOR UPDATE"
                 ),
                 prefix: scope.prefix,
                 log: false
               )

             cond do
               existing && existing.status != :pending ->
                 scope.repo.rollback(:ineligible_recheck)

               existing && existing.source_kind == :arrival ->
                 # Independently verified arrivals never become a wider manual grant.
                 if not Enum.all?(ids, &(&1 in existing.message_ids)),
                   do: scope.repo.rollback(:ineligible_recheck)

               existing ->
                 if existing.authority_id != authority,
                   do: scope.repo.rollback(:ineligible_recheck)

                 if Enum.sort(existing.message_ids) != Enum.sort(ids) do
                   :ok = EmailJanitor.Store.fence_recheck(scope, inbox.id, ids)

                   scope.repo.update!(
                     Ecto.Changeset.change(existing,
                       message_ids: Enum.sort(ids),
                       request_version: existing.request_version + 1,
                       attempts: 0,
                       invalid_attempts: 0,
                       rejected_attempts: 0,
                       contract_blocked: false,
                       requested: false,
                       next_attempt_at: nil
                     ),
                     prefix: scope.prefix,
                     log: false
                   )
                 end

               true ->
                 now = DateTime.utc_now()

                 scope.repo.insert!(
                   %{
                     source
                     | generation: checkpoint.generation,
                       requested: false,
                       inserted_at: now,
                       updated_at: now
                   },
                   prefix: scope.prefix,
                   log: false
                 )
             end

             # Preserve requested backoff and every cap on repeated host discovery.
             scope.repo.update_all(
               from(p in Candidate,
                 where:
                   p.inbox_id == ^inbox.id and
                     p.candidate_id == ^id and p.status == :pending and not p.requested and
                     not p.contract_blocked and p.invalid_attempts < 8 and p.rejected_attempts < 4
               ),
               [set: [requested: true, next_attempt_at: nil], inc: [request_version: 1]],
               prefix: scope.prefix,
               log: false
             )

             :ok
           end) do
        {:ok, :ok} -> :ok
        _ -> {:error, :ineligible_recheck}
      end
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
        order_by: [asc_nulls_first: c.next_attempt_at, asc: c.updated_at, asc: c.candidate_id],
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
         true <-
           address == inbox.address and fresh.request_version == candidate.request_version and
             pending_source?(scope, inbox, fresh) do
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
          p.inbox_id == ^inbox.id and p.status == :pending and not p.requested and
            p.invalid_attempts < 8 and p.rejected_attempts < 4 and not p.contract_blocked and
            ((not is_nil(c.id) and c.thread_id == p.thread_id and
                fragment(
                  "? <@ COALESCE(?, ?)",
                  p.message_ids,
                  c.remaining_message_ids,
                  c.message_ids
                )) or
               (a.state == :cancelled and is_nil(a.dispatch_started_at) and
                  a.thread_id == p.thread_id and
                  fragment(
                    "? <@ COALESCE(?, ?)",
                    p.message_ids,
                    a.remaining_metadata_ids,
                    a.message_ids
                  ))),
        select: p.candidate_id
      )

    {count, _} =
      scope.repo.update_all(
        from(p in Candidate,
          where:
            p.inbox_id == ^inbox.id and not p.requested and p.invalid_attempts < 8 and
              p.rejected_attempts < 4 and not p.contract_blocked and
              p.candidate_id in subquery(candidates)
        ),
        [
          set: [
            requested: true,
            attempts: 0,
            invalid_attempts: 0,
            rejected_attempts: 0,
            next_attempt_at: nil
          ],
          inc: [request_version: 1]
        ],
        prefix: scope.prefix,
        log: false
      )

    {:ok, count}
  end

  def finish_candidate(scope, inbox, candidate, result, now) do
    case result do
      :unsupported_policy ->
        scope.repo.update_all(
          from(c in Candidate,
            where:
              c.inbox_id == ^inbox.id and
                c.candidate_id == ^candidate.candidate_id and
                c.request_version == ^candidate.request_version
          ),
          [set: [requested: false, contract_blocked: true, next_attempt_at: nil]],
          prefix: scope.prefix,
          log: false
        )

      status when status in [:retry, :unreadable, :invalid_decision, :model_rejected] ->
        attempts = min(candidate.attempts + 1, 16)

        invalid_attempts =
          if status == :invalid_decision, do: min(candidate.invalid_attempts + 1, 8), else: 0

        rejected_attempts =
          if status == :model_rejected, do: min(candidate.rejected_attempts + 1, 4), else: 0

        capped = invalid_attempts >= 8 or rejected_attempts >= 4

        scope.repo.update_all(
          from(c in Candidate,
            where:
              c.inbox_id == ^inbox.id and c.candidate_id == ^candidate.candidate_id and
                c.request_version == ^candidate.request_version and
                c.status == :pending
          ),
          [
            set: [
              attempts: attempts,
              invalid_attempts: invalid_attempts,
              rejected_attempts: rejected_attempts,
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
            where:
              c.inbox_id == ^inbox.id and c.candidate_id == ^candidate.candidate_id and
                c.request_version == ^candidate.request_version
          ),
          [set: [requested: false, next_attempt_at: nil]],
          prefix: scope.prefix,
          log: false
        )
    end

    :ok
  end

  # Bound distinct bad model results across conversations, without retaining any
  # response text. A valid classification resets the streak; safeguards do not.
  def model_outcome(scope, inbox, thread, version, result, now) do
    bad? = result in [{:error, :model_rejected}, {:error, :invalid_decision}]
    good? = match?({:ok, %EmailJanitor.Proposal{}}, result) or result == {:keep, :classifier_kept}

    if bad? or good? do
      case scope.repo.transaction(fn ->
             mailbox =
               scope.repo.one(
                 from(m in Mailbox,
                   where: m.id == ^inbox.id,
                   lock: "FOR NO KEY UPDATE"
                 ),
                 prefix: scope.prefix,
                 log: false
               )

             if mailbox && mailbox.instruction_version == version do
               if good? do
                 scope.repo.delete_all(from(s in ModelStreak, where: s.inbox_id == ^inbox.id),
                   prefix: scope.prefix,
                   log: false
                 )

                 false
               else
                 old = scope.repo.get(ModelStreak, inbox.id, prefix: scope.prefix, log: false)

                 previous =
                   if old && old.instruction_version == version, do: old.bad_threads, else: []

                 threads = Enum.uniq(previous ++ [thread]) |> Enum.take(4)

                 scope.repo.insert_all(
                   ModelStreak,
                   [
                     %{
                       inbox_id: inbox.id,
                       instruction_version: version,
                       bad_threads: threads,
                       inserted_at: now,
                       updated_at: now
                     }
                   ],
                   prefix: scope.prefix,
                   log: false,
                   conflict_target: [:inbox_id],
                   on_conflict: {:replace, [:instruction_version, :bad_threads, :updated_at]}
                 )

                 length(threads) >= 4
               end
             else
               false
             end
           end) do
        {:ok, throttled?} -> throttled?
        _ -> raise "worker metadata unavailable"
      end
    else
      false
    end
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
          pending.remaining_message_ids || pending.message_ids

        action && action.state == :cancelled && is_nil(action.dispatch_started_at) &&
            action.thread_id == candidate.thread_id ->
          action.remaining_metadata_ids || action.message_ids

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
