defmodule EmailJanitor.Store do
  @moduledoc "Scoped durable intents and restoration history. No raw email or provider output is accepted."
  import Ecto.Query
  alias EmailJanitor.{Inbox, Owner, Policy, Proposal, Reconciliation}

  alias EmailJanitor.Store.{
    Action,
    Candidate,
    CandidateMigration,
    Mailbox,
    Migration,
    Scope,
    ReviewFence,
    TargetMigration
  }

  def install(%Scope{repo: repo, prefix: prefix}) do
    Ecto.Adapters.SQL.query!(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"), [], log: false)
    Ecto.Migrator.up(repo, 1, Migration, prefix: prefix, log: false)
    Ecto.Migrator.up(repo, 2, CandidateMigration, prefix: prefix, log: false)
    Ecto.Migrator.up(repo, 6, TargetMigration, prefix: prefix, log: false)
  end

  def add_inbox(%Scope{} = scope, %Inbox{} = inbox) do
    scope.repo.transaction(fn ->
      EmailJanitor.Preferences.Lock.acquire(scope, :shared)

      case scope.repo.insert(%Mailbox{id: inbox.id, address: inbox.address}, prefix: scope.prefix) do
        {:ok, mailbox} -> mailbox
        {:error, reason} -> scope.repo.rollback(reason)
      end
    end)
  end

  def instruction_version(%Scope{} = scope, inbox_id) do
    case scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix) do
      nil -> {:error, :unknown_inbox}
      mailbox -> {:ok, mailbox.instruction_version}
    end
  end

  def review_snapshot(%Scope{} = scope, inbox_id) do
    case scope.repo.one(
           from(m in Mailbox,
             where: m.id == ^inbox_id,
             select: {m.instruction_version, fragment("clock_timestamp()")}
           ),
           prefix: scope.prefix
         ) do
      nil -> {:error, :unknown_inbox}
      snapshot -> {:ok, snapshot}
    end
  end

  def intent(%Scope{} = scope, inbox_id, %Proposal{} = proposal, history_id, opts \\ [])
      when is_binary(history_id) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: do_intent(scope, inbox_id, proposal, history_id, opts)
  end

  defp do_intent(scope, inbox_id, proposal, history_id, opts) do
    true = Regex.match?(~r/\A[0-9]{1,32}\z/, history_id)

    record = %Action{
      id: Ecto.UUID.generate(),
      inbox_id: inbox_id,
      thread_id: proposal.thread_id,
      message_ids: proposal.message_ids,
      message_categories:
        Map.new(Proposal.categories(proposal), fn {id, category} ->
          {id, Atom.to_string(category)}
        end),
      fingerprint: proposal.fingerprint,
      history_id: history_id,
      instruction_version: proposal.instruction_version,
      category: proposal.category,
      state: :intent
    }

    scope.repo.transaction(fn ->
      # Serialize reservations even for different reviews of the same message.
      # Label/prompt changes must never bypass an earlier ambiguous mutation.
      mailbox =
        scope.repo.one!(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      if mailbox.instruction_version != proposal.instruction_version,
        do: scope.repo.rollback(:proposal_changed)

      existing =
        scope.repo.one(
          from(a in Action,
            where:
              a.inbox_id == ^inbox_id and a.state in [:intent, :unresolved, :done, :restored] and
                fragment("? && ?::text[]", a.message_ids, ^proposal.message_ids),
            order_by: [asc: a.inserted_at],
            limit: 1
          ),
          prefix: scope.prefix
        )

      review_started_at = Keyword.get_lazy(opts, :review_started_at, fn -> clock(scope) end)
      evaluated_ids = Proposal.evaluated_ids(proposal)

      # Every accepted evaluation is authoritative, including Keep targets when
      # its Done subset already belongs to a durable action. Older retries may
      # still settle that action, but must not overwrite newer review evidence.
      newer_candidate? =
        scope.repo.exists?(
          from(c in Candidate,
            where:
              c.inbox_id == ^inbox_id and c.updated_at > ^review_started_at and
                fragment(
                  "COALESCE(?, ?) && ?::text[]",
                  c.evaluated_message_ids,
                  c.message_ids,
                  ^evaluated_ids
                )
          ),
          prefix: scope.prefix
        )

      stale? =
        newer_candidate? or newer_review?(scope, inbox_id, evaluated_ids, review_started_at)

      if existing do
        unless stale? do
          policy = Keyword.get(opts, :policy, Policy.unlimited())

          retire_overlapping_candidates(
            scope,
            inbox_id,
            existing,
            policy,
            review_started_at,
            proposal,
            # An overlapping action may cover only a subset of fresh Done IDs.
            # Retire covered work and fresh Keeps, retaining uncovered Done work.
            Enum.filter(
              evaluated_ids,
              &(&1 in existing.message_ids or &1 not in proposal.message_ids)
            )
          )

          # A fence for uncovered Done work needs a durable pending owner;
          # otherwise an agreeing cached executor must remain able to admit it.
          uncovered = proposal.message_ids -- existing.message_ids

          pending_ids =
            scope.repo.all(
              from(c in Candidate,
                where:
                  c.inbox_id == ^inbox_id and
                    fragment("? && ?::text[]", c.message_ids, ^uncovered),
                select: {c.remaining_message_ids, c.message_ids}
              ),
              prefix: scope.prefix
            )
            |> Enum.flat_map(fn {remaining, original} -> remaining || original end)

          fence_ids = Enum.filter(evaluated_ids, &(&1 not in uncovered or &1 in pending_ids))
          record_review(scope, inbox_id, review_ids(fence_ids, opts))
        end

        {:existing, existing}
      else
        if stale?, do: scope.repo.rollback(:proposal_changed)

        ids = Enum.sort(proposal.message_ids)
        message_key = :crypto.hash(:sha256, :erlang.term_to_binary(ids))

        candidate =
          scope.repo.get_by(Candidate, [inbox_id: inbox_id, message_key: message_key],
            prefix: scope.prefix
          ) ||
            scope.repo.insert!(
              %Candidate{
                inbox_id: inbox_id,
                thread_id: proposal.thread_id,
                message_key: message_key,
                message_ids: ids,
                inserted_at: clock(scope),
                updated_at: clock(scope)
              },
              prefix: scope.prefix
            )

        if candidate.message_ids != ids, do: scope.repo.rollback(:candidate_conflict)

        candidate =
          candidate
          |> Ecto.Changeset.change(
            thread_id: proposal.thread_id,
            updated_at: clock(scope),
            evaluated_message_ids: evaluated_ids,
            remaining_message_ids: ids
          )
          |> scope.repo.update!(prefix: scope.prefix)

        record = %{record | id: candidate.id}
        policy = Keyword.get(opts, :policy, Policy.unlimited())
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

        admission = %Policy.Admission{inbox_message_ids: Proposal.inbox_ids(proposal)}

        case Policy.reserve(policy, inbox_id, record.id, proposal.message_ids, now, admission) do
          :ok ->
            retire_overlapping_candidates(
              scope,
              inbox_id,
              candidate,
              policy,
              review_started_at,
              proposal
            )

            record = struct(record, Owner.capture())
            record = %{record | lease_expires_at: DateTime.add(clock(scope), 60)}
            action = scope.repo.insert!(record, prefix: scope.prefix)
            scope.repo.delete!(candidate, prefix: scope.prefix)
            record_review(scope, inbox_id, review_ids(evaluated_ids, opts))
            {:created, action}

          # A block commits the host's pending-candidate metadata but never creates
          # a Gmail mutation intent. Errors roll back the entire reservation.
          {:blocked, reason} ->
            retire_overlapping_candidates(
              scope,
              inbox_id,
              candidate,
              policy,
              review_started_at,
              proposal
            )

            record_review(scope, inbox_id, review_ids(evaluated_ids, opts))

            {:blocked, reason}

          {:error, reason} ->
            scope.repo.rollback(reason)
        end
      end
    end)
  end

  defp retire_overlapping_candidates(
         scope,
         inbox_id,
         current,
         policy,
         started_at,
         proposal,
         evaluated_ids \\ nil
       ) do
    opts = [
      evaluated_message_ids: evaluated_ids || Proposal.evaluated_ids(proposal),
      inbox_message_ids: Proposal.inbox_ids(proposal)
    ]

    prior =
      scope.repo.all(
        from(c in Candidate,
          where:
            c.inbox_id == ^inbox_id and c.id != ^current.id and c.updated_at <= ^started_at and
              (c.thread_id == ^current.thread_id or
                 fragment("? && ?::text[]", c.message_ids, ^current.message_ids))
        ),
        prefix: scope.prefix
      )

    for candidate <- prior do
      retire_candidate!(scope, policy, inbox_id, candidate, opts)
    end

    cancelled =
      scope.repo.all(
        from(a in Action,
          where:
            a.inbox_id == ^inbox_id and a.state == :cancelled and a.updated_at <= ^started_at and
              (a.thread_id == ^current.thread_id or
                 fragment("? && ?::text[]", a.message_ids, ^current.message_ids))
        ),
        prefix: scope.prefix
      )

    for action <- cancelled,
        do:
          retire_metadata!(
            scope,
            policy,
            inbox_id,
            action.id,
            retirement_ids(action.message_ids, opts)
          )

    :ok
  end

  @doc "Retire fresh keep reviews while preserving newer work and instruction edits."
  def retire_ineligible(
        %Scope{} = scope,
        inbox_id,
        thread_id,
        version,
        %DateTime{} = started_at,
        opts \\ []
      ) do
    scope.repo.transaction(fn ->
      mailbox =
        scope.repo.one!(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      if mailbox.instruction_version != version, do: scope.repo.rollback(:proposal_changed)
      evaluated = Keyword.get(opts, :evaluated_message_ids, [])
      fence_ids = review_ids(evaluated, opts)

      if newer_review?(scope, inbox_id, fence_ids, started_at),
        do: scope.repo.rollback(:proposal_changed)

      policy = Keyword.get(opts, :policy, Policy.unlimited())

      candidates =
        scope.repo.all(
          from(c in Candidate,
            where:
              c.inbox_id == ^inbox_id and c.thread_id == ^thread_id and
                c.updated_at <= ^started_at
          ),
          prefix: scope.prefix
        )

      for candidate <- candidates do
        retire_candidate!(scope, policy, inbox_id, candidate, opts)
      end

      cancelled =
        scope.repo.all(
          from(a in Action,
            where:
              a.inbox_id == ^inbox_id and a.thread_id == ^thread_id and a.state == :cancelled and
                a.updated_at <= ^started_at
          ),
          prefix: scope.prefix
        )

      for action <- cancelled,
          do:
            retire_metadata!(
              scope,
              policy,
              inbox_id,
              action.id,
              retirement_ids(action.message_ids, opts)
            )

      record_review(scope, inbox_id, fence_ids)
      :retired
    end)
  end

  defp retire_candidate!(scope, policy, inbox_id, candidate, opts) do
    outstanding = candidate.remaining_message_ids || candidate.message_ids
    ids = retirement_ids(outstanding, opts)
    retire_metadata!(scope, policy, inbox_id, candidate.id, ids)

    remaining = outstanding -- ids

    if remaining == [] do
      scope.repo.delete!(candidate, prefix: scope.prefix)
    else
      # Preserve classification time: retirement is not a fresh review of the
      # remaining context members. Stable ID/key retain the original Done set.
      scope.repo.update_all(
        from(c in Candidate, where: c.id == ^candidate.id),
        [set: [remaining_message_ids: remaining]],
        prefix: scope.prefix
      )
    end
  end

  defp newer_review?(_scope, _inbox_id, [], _started_at), do: false

  defp newer_review?(scope, inbox_id, ids, started_at) do
    scope.repo.exists?(
      from(f in ReviewFence,
        where: f.inbox_id == ^inbox_id and f.message_id in ^ids and f.reviewed_at > ^started_at
      ),
      prefix: scope.prefix
    )
  end

  defp record_review(_scope, _inbox_id, []), do: :ok

  defp record_review(scope, inbox_id, ids) do
    now = clock(scope)
    rows = Enum.map(Enum.uniq(ids), &%{inbox_id: inbox_id, message_id: &1, reviewed_at: now})

    scope.repo.insert_all(ReviewFence, rows,
      prefix: scope.prefix,
      conflict_target: [:inbox_id, :message_id],
      on_conflict: {:replace, [:reviewed_at]}
    )

    :ok
  end

  defp review_ids(evaluated, opts) do
    observed = Keyword.get(opts, :observed_message_ids, [])
    inbox_ids = Keyword.get(opts, :inbox_message_ids, [])
    Enum.uniq(evaluated ++ (observed -- inbox_ids))
  end

  defp retirement_ids(ids, opts) do
    case Keyword.fetch(opts, :inbox_message_ids) do
      :error ->
        ids

      {:ok, inbox_ids} ->
        evaluated = Keyword.fetch!(opts, :evaluated_message_ids)
        Enum.filter(ids, &(&1 in evaluated or &1 not in inbox_ids))
    end
  end

  defp retire_metadata!(_scope, _policy, _inbox_id, _id, []), do: :ok

  defp retire_metadata!(scope, policy, inbox_id, id, ids) do
    case Policy.retire_candidate(policy, inbox_id, id, ids) do
      :ok -> :ok
      {:error, reason} -> scope.repo.rollback(reason)
    end
  end

  def get(%Scope{} = scope, inbox_id, id) do
    scope.repo.one(from(a in Action, where: a.id == ^id and a.inbox_id == ^inbox_id),
      prefix: scope.prefix
    )
  end

  @doc "Read the current durable action and settle while transitions are excluded."
  def with_locked_action(%Scope{} = scope, inbox_id, id, fun) do
    scope.repo.transaction(fn ->
      mailbox =
        scope.repo.one(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      if is_nil(mailbox), do: scope.repo.rollback(:unknown_action)

      action =
        scope.repo.one(
          from(a in Action, where: a.id == ^id and a.inbox_id == ^inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      if is_nil(action), do: scope.repo.rollback(:unknown_action)
      fun.(action)
    end)
  end

  @doc "Fence an owner immediately before dispatch. Expired or different processes cannot send."
  def begin_dispatch(%Scope{} = scope, inbox_id, id, token) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: do_begin_dispatch(scope, inbox_id, id, token)
  end

  defp do_begin_dispatch(scope, inbox_id, id, token) do
    case scope.repo.transaction(fn ->
           mailbox =
             scope.repo.one(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
               prefix: scope.prefix
             )

           action =
             scope.repo.one(
               from(a in Action,
                 where: a.id == ^id and a.inbox_id == ^inbox_id,
                 lock: "FOR UPDATE"
               ),
               prefix: scope.prefix
             )

           with %Action{} <- action, true <- Owner.owns?(action) do
             if is_nil(mailbox) or mailbox.instruction_version != action.instruction_version,
               do: scope.repo.rollback(:proposal_changed)

             {count, _} =
               scope.repo.update_all(
                 from(a in Action,
                   where:
                     a.id == ^id and a.inbox_id == ^inbox_id and a.state == :intent and
                       a.owner_token == ^token and
                       a.lease_expires_at > fragment("clock_timestamp()") and
                       is_nil(a.dispatch_started_at),
                   update: [
                     set: [
                       dispatch_started_at: fragment("clock_timestamp()"),
                       lease_expires_at: fragment("clock_timestamp() + interval '120 seconds'"),
                       updated_at: fragment("clock_timestamp()")
                     ]
                   ]
                 ),
                 [],
                 prefix: scope.prefix
               )

             if count == 1, do: :ok, else: scope.repo.rollback(:ownership_lost)
           else
             _ -> scope.repo.rollback(:ownership_lost)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancel only this owner's action before its dispatch fence ever succeeded."
  def cancel_prepared(%Scope{} = scope, inbox_id, id, token) do
    with %Action{} = action <- get(scope, inbox_id, id), true <- Owner.owns?(action) do
      {count, _} =
        scope.repo.update_all(
          from(a in Action,
            where:
              a.id == ^id and a.inbox_id == ^inbox_id and a.owner_token == ^token and
                a.state == :intent and is_nil(a.dispatch_started_at)
          ),
          [set: [state: :cancelled, updated_at: clock(scope)]],
          prefix: scope.prefix
        )

      if count == 1, do: :ok, else: {:error, :state_changed}
    else
      _ -> {:error, :state_changed}
    end
  end

  @doc "Recover only a provably dead owner; expiry never licenses a live/unknown executor's replay."
  def recover(%Scope{} = scope, inbox_id, id) do
    scope.repo.transaction(fn ->
      scope.repo.one!(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
        prefix: scope.prefix
      )

      # Lock the dispatch fence too: an in-flight UPDATE must finish before we
      # decide whether the dead owner ever dispatched. Mailbox locking alone
      # does not serialize begin_dispatch/4.
      action =
        scope.repo.one(
          from(a in Action, where: a.id == ^id and a.inbox_id == ^inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      with %Action{state: :intent} <- action do
        now = clock(scope)

        proof =
          case Owner.proof(action) do
            :alive ->
              if DateTime.compare(action.lease_expires_at, now) != :gt,
                do: Owner.stop(action),
                else: :alive

            other ->
              other
          end

        if proof != :dead, do: scope.repo.rollback(:owner_not_proven_dead)

        now = clock(scope)

        next = if is_nil(action.dispatch_started_at), do: :cancelled, else: :unresolved
        dispatched = next == :unresolved

        {count, _} =
          scope.repo.update_all(
            from(a in Action,
              where:
                a.id == ^id and a.inbox_id == ^inbox_id and a.state == :intent and
                  a.owner_token == ^action.owner_token and
                  (^dispatched or is_nil(a.dispatch_started_at))
            ),
            [set: [state: next, recovered_at: now, updated_at: now]],
            prefix: scope.prefix
          )

        if count == 1,
          do: {next, get(scope, inbox_id, id)},
          else: scope.repo.rollback(:state_changed)
      else
        nil -> scope.repo.rollback(:unknown_action)
        %Action{} -> scope.repo.rollback(:state_changed)
      end
    end)
  end

  def transition(%Scope{} = scope, inbox_id, id, from_state, to_state)
      when {from_state, to_state} in [
             intent: :done,
             intent: :unresolved,
             done: :restored
           ] do
    with %Action{} = action <- get(scope, inbox_id, id),
         true <- from_state != :intent or Owner.owns?(action) do
      outcomes =
        case to_state do
          :done -> [applied_message_ids: action.message_ids]
          :restored -> [restored_message_ids: action.applied_message_ids]
          _ -> []
        end

      {count, _} =
        scope.repo.update_all(
          from(a in Action,
            where:
              a.id == ^id and a.inbox_id == ^inbox_id and a.state == ^from_state and
                a.owner_token == ^action.owner_token
          ),
          [set: [state: to_state, updated_at: clock(scope)] ++ outcomes],
          prefix: scope.prefix
        )

      if count == 1, do: :ok, else: {:error, :state_changed}
    else
      _ -> {:error, :state_changed}
    end
  end

  @doc "Resolve an uncertain batch from complete Gmail history, never a raw cancellation."
  def reconcile(%Scope{} = scope, inbox_id, id, history) do
    scope.repo.transaction(fn ->
      scope.repo.one!(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
        prefix: scope.prefix
      )

      action = get(scope, inbox_id, id)

      # A live executor owns :intent. Even complete history fetched before its
      # network request completes cannot prove the mutation did not happen.
      with %Action{state: :unresolved} <- action,
           :ok <- fresh_recovery_history(action, history),
           {:ok, resolution} <- Reconciliation.resolve(action, history),
           :ok <- recovery_outcome(action, resolution) do
        # Mixed batches stay blocked as a whole. Do not unprotect removed/restored
        # IDs merely to retry an unseen member; a later per-message recovery worker
        # may split immutable outcomes. No such worker is claimed in this slice.
        next =
          cond do
            resolution.removed_ids == [] -> :cancelled
            resolution.restored_ids != [] -> :restored
            true -> :done
          end

        {count, _} =
          scope.repo.update_all(
            from(a in Action,
              where: a.id == ^id and a.inbox_id == ^inbox_id and a.state == :unresolved
            ),
            [
              set: [
                state: next,
                applied_message_ids: resolution.removed_ids,
                restored_message_ids: resolution.restored_ids,
                updated_at: clock(scope)
              ]
            ],
            prefix: scope.prefix
          )

        if count == 1, do: {next, resolution}, else: scope.repo.rollback(:state_changed)
      else
        nil -> scope.repo.rollback(:unknown_action)
        %Action{} -> scope.repo.rollback(:state_changed)
        {:error, reason} -> scope.repo.rollback(reason)
      end
    end)
  end

  def restored_ids(%Scope{} = scope, inbox_id) do
    scope.repo.all(
      from(a in Action,
        where: a.inbox_id == ^inbox_id and a.state == :restored,
        select: a.restored_message_ids
      ),
      prefix: scope.prefix
    )
    |> List.flatten()
    |> MapSet.new()
  end

  defp fresh_recovery_history(%Action{dispatch_started_at: nil}, _), do: :ok

  defp fresh_recovery_history(%Action{} = action, %{
         started_at: %DateTime{} = started
       }) do
    anchor = action.recovered_at || action.updated_at

    if DateTime.compare(started, anchor) != :lt,
      do: :ok,
      else: {:error, :fresh_history_required}
  end

  defp fresh_recovery_history(_, _), do: {:error, :fresh_history_required}

  # A request already sent to Gmail can finish after its local owner dies.
  # Empty history is an observation, not proof of permanent non-application.
  # Only positive outcomes for every dispatched ID settle such an orphan.
  defp recovery_outcome(%Action{dispatch_started_at: nil}, _), do: :ok
  defp recovery_outcome(_, %{retry_ids: []}), do: :ok
  defp recovery_outcome(_, _), do: {:error, :dispatch_outcome_unknown}

  defp clock(scope) do
    %{rows: [[now]]} =
      Ecto.Adapters.SQL.query!(scope.repo, "SELECT clock_timestamp()", [], log: false)

    now
  end
end
