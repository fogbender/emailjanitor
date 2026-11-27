defmodule EmailJanitor.Worker do
  @moduledoc """
  One bounded inbox step. Configuration, credentials, scopes and policy belong to
  the host; only IDs, revision hashes, versions and fixed outcomes are durable.
  Call install/1 during trusted scope setup, never while serving a model tool.
  """
  alias EmailJanitor.{Content, Executor, Policy, Store}
  alias EmailJanitor.Gmail.{Ingestion, ThreadSnapshot}
  alias EmailJanitor.Worker.{Config, Gate, Ledger, Deferral}

  @fixed_errors [
    :authorization_required,
    :forbidden,
    :rate_limited,
    :wrong_inbox,
    :history_gap,
    :history_expired,
    :proposal_changed,
    :instructions_changed,
    :model_unavailable,
    :invalid_decision,
    :eligibility_unavailable,
    :generation_changed,
    :self_mail_unavailable,
    :outer_transaction,
    :connection_changed,
    :activation_failed,
    :invalid_activation,
    :model_rejected,
    :policy_unavailable,
    :partial_retirement_unsupported,
    :manual_recheck_unsupported,
    :manual_authorization_changed,
    :gmail_unavailable,
    :unreadable_content,
    :invalid_thread_snapshot
  ]

  def install(scope), do: Ledger.install(scope)

  @doc "Queue an identified candidate, never arbitrary Gmail IDs. Admission still requires host paid/unlimited authorization."
  def queue_recheck(scope, inbox, candidate_id),
    do: protect(fn -> Ledger.queue_candidate(scope, inbox, candidate_id) end)

  @doc "Queue known pending and proven-unapplied candidate provenance after a host-authorized upgrade."
  def queue_backlog(scope, inbox), do: protect(fn -> Ledger.queue_backlog(scope, inbox) end)

  @doc "Trusted host only: enqueue an authenticated explicit Done selection backed by a host-owned durable grant."
  def queue_manual(scope, inbox, candidate_id, thread_id, ids, options \\ []),
    do:
      protect(fn -> Ledger.queue_manual(scope, inbox, candidate_id, thread_id, ids, options) end)

  def step(%Config{} = config) do
    if config.scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      protect(fn ->
        now = config.clock.() |> utc()
        recovery = recover_one(config, now)
        result = run_inbox(config, now)
        # Reports have fixed atoms only; never report raw SDK/model envelopes.
        status = status(result)
        report(config, report_status(result))

        {:ok,
         %{
           status: status,
           recovery: recovery,
           more?: more?(result) or local_work_due?(config, now)
         }}
      end)
    end
  end

  defp run_inbox(config, now) do
    with :ok <- authorized(config),
         {:ok, %Content{} = instructions, version} when is_integer(version) and version > 0 <-
           config.preferences.(),
         {:ok, checkpoint} <- connected(config, now, version),
         true <- checkpoint.status == :active,
         :ok <- renew(config, checkpoint, now),
         {:ok, history} <- Ingestion.catch_up(config.scope, config.inbox, config.gmail),
         {:ok, checkpoint} <- Ingestion.checkpoint(config.scope, config.inbox.id) do
      result =
        case Ledger.candidate_due(config.scope, config.inbox, now) do
          nil ->
            cleanup_one(config, checkpoint, instructions, version, now)

          candidate ->
            recheck_candidate(config, checkpoint, candidate, instructions, version, now)
        end

      {result, history.more?}
    else
      false -> {:error, :history_gap}
      error -> error
    end
  end

  defp connected(config, now, version) do
    options = [on_baseline: config.on_baseline, expected_instruction_version: version]

    case Ingestion.checkpoint(config.scope, config.inbox.id) do
      {:error, :not_initialized} ->
        create_baseline(config, now, options, nil)

      {:ok, checkpoint} ->
        case config.lifecycle do
          {:reconnect, expected} when expected == checkpoint.generation ->
            create_baseline(config, now, options, expected)

          {:reconnect, _} ->
            {:error, :generation_changed}

          :resume ->
            Ingestion.activate(config.scope, config.inbox, checkpoint.generation, options)
        end

      error ->
        error
    end
  end

  defp create_baseline(config, now, activation_options, previous) do
    {gmail, options} = config.gmail

    with {:ok, watch} <- gmail.watch(config.inbox.id, config.topic, options),
         :ok <- authorized(config) do
      result =
        if previous,
          do:
            Ingestion.reconnect(config.scope, config.inbox, previous, watch, activation_options),
          else: Ingestion.baseline(config.scope, config.inbox, watch, activation_options)

      case result do
        {:ok, checkpoint} ->
          Ledger.watched(config.scope, config.inbox, checkpoint.generation, now)
          {:ok, checkpoint}

        error ->
          error
      end
    end
  end

  defp renew(config, checkpoint, now) do
    if Ledger.watch_due?(config.scope, config.inbox, checkpoint, now) do
      with :ok <- authorized(config) do
        case protect(fn ->
               Ingestion.renew_watch(config.scope, config.inbox, config.topic, config.gmail)
             end) do
          {:ok, _} ->
            Ledger.watched(config.scope, config.inbox, checkpoint.generation, now)

          _ ->
            :ok = Ledger.watch_failed(config.scope, config.inbox, checkpoint.generation, now)
            report(config, :watch_renewal_failed)
            # An active durable cursor still supports periodic history catch-up.
            :ok
        end
      end
    else
      :ok
    end
  end

  defp cleanup_one(config, checkpoint, instructions, version, now) do
    case Ledger.arrival_due(config.scope, config.inbox, checkpoint, version, now) do
      nil ->
        :idle

      arrival ->
        Ledger.attempted(
          config.scope,
          config.inbox,
          checkpoint.generation,
          arrival.message_id,
          now
        )

        review_arrival(config, checkpoint, arrival.message_id, instructions, version, now)
    end
  end

  defp review_arrival(config, checkpoint, id, instructions, version, now) do
    {gmail, options} = config.gmail

    with :ok <- authorized(config),
         {:ok, thread} <- gmail.thread_id(config.inbox.id, id, options) do
      case gmail.thread_snapshot(config.inbox.id, thread, options) do
        {:ok, %ThreadSnapshot{thread_id: ^thread} = snapshot} ->
          deferred = Ledger.deferral(config.scope, config.inbox, checkpoint.generation, thread)

          if stable_deferral?(deferred, snapshot, version) do
            ids = Enum.uniq([id | deferred.message_ids])

            Ledger.defer(
              config.scope,
              config.inbox,
              checkpoint.generation,
              thread,
              snapshot.fingerprint,
              version,
              ids,
              deferred.status,
              now
            )

            :deferred
          else
            review_targets(config, checkpoint, id, snapshot, instructions, version, now)
          end

        {:error, :thread_not_found} ->
          processed(config, checkpoint, [id], :skipped)

        error ->
          pre_review_failure(config, checkpoint, id, thread, version, now, error)
      end
    else
      {:error, :message_not_found} -> processed(config, checkpoint, [id], :skipped)
      error -> pre_review_failure(config, checkpoint, id, "arrival:" <> id, version, now, error)
    end
  end

  defp stable_deferral?(
         %Deferral{status: status, instruction_version: version, fingerprint: fp},
         %ThreadSnapshot{fingerprint: fp},
         version
       )
       when status in [:unreadable, :blocked],
       do: true

  defp stable_deferral?(_, _, _), do: false

  defp pre_review_failure(
         config,
         checkpoint,
         id,
         key,
         version,
         now,
         error,
         fingerprint \\ "metadata-unavailable"
       ) do
    old = Ledger.deferral(config.scope, config.inbox, checkpoint.generation, key)

    ids =
      if old && old.instruction_version == version,
        do: Enum.uniq([id | old.message_ids]),
        else: [id]

    status =
      if error in [{:error, :unreadable_content}, {:error, :invalid_thread_snapshot}],
        do: :unreadable,
        else: :transient

    Ledger.defer(
      config.scope,
      config.inbox,
      checkpoint.generation,
      key,
      fingerprint,
      version,
      ids,
      status,
      now
    )

    # A handled local failure must not activate the inbox-wide scheduler backoff,
    # otherwise that backoff can always outlast the item's own retry deferral.
    if inbox_failure?(error), do: error, else: {:deferred, status(error)}
  end

  defp inbox_failure?({:error, reason})
       when reason in [
              :authorization_required,
              :forbidden,
              :rate_limited,
              :wrong_inbox,
              :connection_changed,
              :model_unavailable,
              :gmail_unavailable,
              :not_found,
              :eligibility_unavailable,
              :self_mail_unavailable,
              :policy_unavailable
            ],
       do: true

  defp inbox_failure?({:deferred, _, {:settlement_pending, _, _}}), do: true
  defp inbox_failure?({:deferred, _, result}), do: inbox_failure?(result)
  defp inbox_failure?(_), do: false

  defp review_targets(config, checkpoint, id, snapshot, instructions, version, now) do
    case Ingestion.eligible_thread(
           config.scope,
           config.inbox,
           checkpoint.generation,
           id,
           config.gmail
         ) do
      {:ok, eligible} ->
        targets =
          Ledger.targets(config.scope, config.inbox, checkpoint.generation, eligible.message_ids)

        if targets == [] do
          processed(config, checkpoint, [id], :skipped)
        else
          options = [
            cleanup_target_ids: targets,
            self_mail: config.self_mail,
            policy: %Policy{adapter: Gate, context: %{config: config}}
          ]

          result =
            Executor.review(
              config.scope,
              config.inbox,
              eligible.thread_id,
              config.gmail,
              config.classifier,
              Content.read(instructions),
              version,
              options
            )

          throttled? =
            Ledger.model_outcome(
              config.scope,
              config.inbox,
              eligible.thread_id,
              version,
              result,
              now
            )

          finished =
            finish_review(config, checkpoint, eligible, targets, snapshot, version, now, result)

          if throttled?, do: result, else: finished
        end

      {:skip, reason} when reason in [:deleted_arrival, :not_in_inbox, :prebaseline_inbox] ->
        processed(config, checkpoint, [id], :skipped)

      error ->
        pre_review_failure(
          config,
          checkpoint,
          id,
          snapshot.thread_id,
          version,
          now,
          error,
          snapshot.fingerprint
        )
    end
  end

  defp finish_review(
         config,
         checkpoint,
         eligible,
         _targets,
         snapshot,
         version,
         now,
         {:keep, :unreadable_content}
       ) do
    Ledger.defer(
      config.scope,
      config.inbox,
      checkpoint.generation,
      eligible.thread_id,
      snapshot.fingerprint,
      version,
      eligible.message_ids,
      :unreadable,
      now
    )

    :deferred
  end

  defp finish_review(config, checkpoint, eligible, targets, _snapshot, _version, _now, {:keep, _}) do
    Ledger.clear_deferral(config.scope, config.inbox, checkpoint.generation, eligible.thread_id)
    processed(config, checkpoint, targets, :kept)
  end

  defp finish_review(
         config,
         checkpoint,
         _eligible,
         targets,
         _snapshot,
         _version,
         _now,
         {:error, :thread_not_found}
       ) do
    processed(config, checkpoint, targets, :skipped)
  end

  defp finish_review(
         config,
         checkpoint,
         eligible,
         targets,
         snapshot,
         version,
         now,
         {:ok, proposal}
       ) do
    gate = %Policy{
      adapter: Gate,
      context: %{config: config, eligible: eligible, proposal: proposal}
    }

    result =
      with :ok <- authorized(config),
           :ok <- Ingestion.authorize_proposal(config.scope, config.inbox, eligible, proposal),
           do:
             Executor.execute(config.scope, config.inbox, proposal, config.gmail,
               policy: gate,
               self_mail: config.self_mail
             )

    case result do
      {:done, _} ->
        processed(config, checkpoint, targets, :done)

      {:error, :thread_not_found} ->
        processed(config, checkpoint, targets, :skipped)

      {:deferred, covering_id, _} = deferred ->
        # A terminal covering action may own only part of this new selection.
        # Retire only its confirmed applied IDs so the uncovered arrivals can
        # form a fresh subset next time instead of repeating the same overlap.
        covered =
          case Store.get(config.scope, config.inbox.id, covering_id) do
            %Store.Action{state: state, applied_message_ids: ids}
            when state in [:done, :restored] and is_list(ids) ->
              Enum.filter(targets, &(&1 in ids))

            _ ->
              []
          end

        with :existing <-
               if(covered == [],
                 do: :existing,
                 else: processed(config, checkpoint, covered, :existing)
               ) do
          Ledger.defer(
            config.scope,
            config.inbox,
            checkpoint.generation,
            eligible.thread_id,
            snapshot.fingerprint,
            version,
            eligible.message_ids -- covered,
            :transient,
            now
          )

          if inbox_failure?(deferred), do: deferred, else: :deferred
        end

      {:blocked, reason} when reason in [:already_reserved, :action_settled] ->
        Ledger.defer(
          config.scope,
          config.inbox,
          checkpoint.generation,
          eligible.thread_id,
          snapshot.fingerprint,
          version,
          eligible.message_ids,
          :transient,
          now
        )

        :deferred

      {:error, :unreadable_content} ->
        finish_review(
          config,
          checkpoint,
          eligible,
          targets,
          snapshot,
          version,
          now,
          {:keep, :unreadable_content}
        )

      {:error, reason}
      when reason in [:partial_admission_unsupported, :partial_retirement_unsupported] ->
        Ledger.defer(
          config.scope,
          config.inbox,
          checkpoint.generation,
          eligible.thread_id,
          snapshot.fingerprint,
          version,
          eligible.message_ids,
          :blocked,
          now
        )

        :blocked

      {:skip, reason} when reason != :proposal_changed ->
        processed(config, checkpoint, targets, :skipped)

      {:blocked, _} ->
        processed(config, checkpoint, targets, :blocked)

      {:unresolved, _} ->
        processed(config, checkpoint, targets, :unresolved)

      {:existing, _, _} ->
        processed(config, checkpoint, targets, :existing)

      {:settlement_pending, _, _} ->
        processed(config, checkpoint, targets, :settlement_pending)

      _ ->
        Ledger.defer(
          config.scope,
          config.inbox,
          checkpoint.generation,
          eligible.thread_id,
          snapshot.fingerprint,
          version,
          eligible.message_ids,
          :transient,
          now
        )

        if inbox_failure?(result), do: result, else: {:deferred, status(result)}
    end
  end

  defp finish_review(config, checkpoint, eligible, _targets, snapshot, version, now, error) do
    old = Ledger.deferral(config.scope, config.inbox, checkpoint.generation, eligible.thread_id)

    same? = old && old.instruction_version == version && old.fingerprint == snapshot.fingerprint

    capped =
      same? &&
        ((error == {:error, :invalid_decision} and old.status == :invalid and old.attempts >= 7) or
           (error == {:error, :model_rejected} and old.status == :rejected and old.attempts >= 3))

    Ledger.defer(
      config.scope,
      config.inbox,
      checkpoint.generation,
      eligible.thread_id,
      snapshot.fingerprint,
      version,
      eligible.message_ids,
      cond do
        capped -> :blocked
        error == {:error, :invalid_decision} -> :invalid
        error == {:error, :model_rejected} -> :rejected
        error == {:error, :partial_retirement_unsupported} -> :blocked
        true -> :transient
      end,
      now
    )

    if inbox_failure?(error), do: error, else: {:deferred, status(error)}
  end

  defp recheck_candidate(config, checkpoint, candidate, instructions, version, now) do
    {gmail, options} = config.gmail

    with :ok <- authorized(config),
         :ok <- Config.recheck(config, candidate),
         :ok <-
           Ledger.candidate_available?(
             config.scope,
             config.inbox,
             candidate,
             checkpoint.generation
           ),
         {:ok, %ThreadSnapshot{} = snapshot} <-
           gmail.thread_snapshot(config.inbox.id, candidate.thread_id, options) do
      deferred =
        Ledger.deferral(config.scope, config.inbox, checkpoint.generation, candidate.thread_id)

      if match?(
           %Deferral{status: :unreadable, instruction_version: ^version, fingerprint: fp}
           when fp == snapshot.fingerprint,
           deferred
         ) do
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :unreadable, now)
        :deferred
      else
        review =
          Executor.review(
            config.scope,
            config.inbox,
            candidate.thread_id,
            config.gmail,
            config.classifier,
            Content.read(instructions),
            version,
            cleanup_target_ids: candidate.message_ids,
            self_mail: config.self_mail,
            policy: %Policy{adapter: Gate, context: %{config: config}}
          )

        throttled? =
          Ledger.model_outcome(
            config.scope,
            config.inbox,
            candidate.thread_id,
            version,
            review,
            now
          )

        finished = finish_recheck(config, checkpoint, candidate, snapshot, version, now, review)
        if throttled?, do: review, else: finished
      end
    else
      {:blocked, :upgrade_required} ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :blocked

      {:error, reason}
      when reason in [:manual_recheck_unsupported, :manual_authorization_changed] ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :unsupported_policy, now)
        {:deferred, reason}

      {:error, :thread_not_found} ->
        retire_deleted_source(config, checkpoint, candidate, version, now)

      {:error, :ineligible_recheck} ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :skipped

      error ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :retry, now)
        if inbox_failure?(error), do: error, else: {:deferred, status(error)}
    end
  end

  defp finish_recheck(
         config,
         checkpoint,
         candidate,
         snapshot,
         version,
         now,
         {:keep, :unreadable_content}
       ) do
    Ledger.defer(
      config.scope,
      config.inbox,
      checkpoint.generation,
      candidate.thread_id,
      snapshot.fingerprint,
      version,
      candidate.message_ids,
      :unreadable,
      now
    )

    Ledger.finish_candidate(config.scope, config.inbox, candidate, :unreadable, now)
    :deferred
  end

  defp finish_recheck(config, _checkpoint, candidate, _snapshot, _version, now, {:keep, _}) do
    Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
    :kept
  end

  defp finish_recheck(
         config,
         checkpoint,
         candidate,
         _snapshot,
         version,
         now,
         {:error, :thread_not_found}
       ) do
    retire_deleted_source(config, checkpoint, candidate, version, now)
  end

  defp finish_recheck(config, checkpoint, candidate, snapshot, version, now, {:ok, proposal}) do
    context = %{
      config: config,
      source: candidate,
      proposal: proposal,
      generation: checkpoint.generation
    }

    result =
      with :ok <- authorized(config),
           :ok <- Config.recheck(config, candidate),
           :ok <-
             Ledger.authorize_candidate(
               config.scope,
               config.inbox,
               candidate,
               proposal,
               checkpoint.generation
             ),
           do:
             Executor.execute(config.scope, config.inbox, proposal, config.gmail,
               policy: %Policy{adapter: Gate, context: context},
               self_mail: config.self_mail
             )

    case result do
      {:done, _} ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :done

      {:error, :thread_not_found} ->
        retire_deleted_source(config, checkpoint, candidate, version, now)

      {:unresolved, _} ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :unresolved

      {:existing, _, _} ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :existing

      {:skip, reason} when reason != :proposal_changed ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :skipped

      {:error, :unreadable_content} ->
        finish_recheck(
          config,
          checkpoint,
          candidate,
          snapshot,
          version,
          now,
          {:keep, :unreadable_content}
        )

      {:error, reason}
      when reason in [:manual_recheck_unsupported, :manual_authorization_changed] ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :unsupported_policy, now)
        {:deferred, reason}

      {:error, reason}
      when reason in [:partial_admission_unsupported, :partial_retirement_unsupported] ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :unsupported_policy, now)
        :blocked

      {:blocked, reason} when reason not in [:already_reserved, :action_settled] ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :done, now)
        :blocked

      error ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :retry, now)
        if inbox_failure?(error), do: error, else: {:deferred, status(error)}
    end
  end

  defp finish_recheck(
         config,
         checkpoint,
         candidate,
         snapshot,
         version,
         now,
         {:error, :unreadable_content}
       ),
       do:
         finish_recheck(
           config,
           checkpoint,
           candidate,
           snapshot,
           version,
           now,
           {:keep, :unreadable_content}
         )

  defp finish_recheck(config, _checkpoint, candidate, _snapshot, _version, now, error) do
    reason =
      case error do
        {:error, reason}
        when reason in [
               :partial_retirement_unsupported,
               :manual_recheck_unsupported,
               :manual_authorization_changed
             ] ->
          :unsupported_policy

        {:error, reason} when reason in [:invalid_decision, :model_rejected] ->
          reason

        _ ->
          :retry
      end

    Ledger.finish_candidate(config.scope, config.inbox, candidate, reason, now)
    if inbox_failure?(error), do: error, else: {:deferred, status(error)}
  end

  defp retire_deleted_source(config, checkpoint, candidate, version, now) do
    policy = %Policy{adapter: Gate, context: %{config: config}}
    guard = fn -> with :ok <- authorized(config), do: Config.recheck(config, candidate) end

    case Ledger.retire_deleted(
           config.scope,
           config.inbox,
           candidate,
           checkpoint.generation,
           version,
           policy,
           guard
         ) do
      :ok ->
        :skipped

      {:error, reason}
      when reason in [
             :partial_retirement_unsupported,
             :manual_recheck_unsupported,
             :manual_authorization_changed
           ] ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :unsupported_policy, now)
        {:deferred, reason}

      error ->
        Ledger.finish_candidate(config.scope, config.inbox, candidate, :retry, now)
        if inbox_failure?(error), do: error, else: {:deferred, status(error)}
    end
  end

  defp processed(config, checkpoint, ids, outcome) do
    case Ingestion.mark_processed(config.scope, config.inbox, checkpoint.generation, ids) do
      {:ok, :ok} -> outcome
      error -> error
    end
  end

  defp recover_one(config, now) do
    case Ledger.action_due(config.scope, config.inbox, now) do
      nil ->
        :idle

      action ->
        result =
          case action.state do
            state when state in [:done, :restored, :cancelled] ->
              Executor.settle_action(config.scope, config.inbox, action.id, policy: config.policy)

            :intent ->
              Executor.recover(config.scope, config.inbox, action.id, policy: config.policy)

            :unresolved ->
              reconcile(config, action)
          end

        current = Store.get(config.scope, config.inbox.id, action.id)

        settled =
          current && current.state in [:done, :restored, :cancelled] && successful?(result)

        # Record only the timestamp observed BEFORE settlement; a concurrent later
        # restore/update must cause another idempotent settlement, never be hidden.
        Ledger.receipt(
          config.scope,
          config.inbox,
          action,
          if(settled, do: :settled, else: :retry),
          now
        )

        if settled do
          case current.state do
            state when state in [:done, :restored] ->
              Ledger.retire_candidate(config.scope, config.inbox, current.id, current.message_ids)

            :cancelled ->
              Ledger.queue_candidate(config.scope, config.inbox, current.id)
          end
        end

        if settled, do: :settled, else: :pending
    end
  end

  defp reconcile(config, action) do
    {gmail, options} = config.gmail

    with :ok <- authorized(config),
         {:ok, history} <- gmail.history(config.inbox.id, action.history_id, options),
         do:
           Executor.reconcile(config.scope, config.inbox, action.id, history,
             policy: config.policy
           )
  end

  defp successful?({:error, _}), do: false
  defp successful?({:settlement_pending, _, _}), do: false
  defp successful?(_), do: true

  defp authorized(config),
    do: if(config.authorize.() == :ok, do: :ok, else: {:error, :connection_changed})

  defp local_work_due?(config, now) do
    action_due = not is_nil(Ledger.action_due(config.scope, config.inbox, now))

    inbox_due =
      with :ok <- authorized(config),
           {:ok, %{status: :active} = checkpoint} <-
             Ingestion.checkpoint(config.scope, config.inbox.id),
           {:ok, version} <- Store.instruction_version(config.scope, config.inbox.id) do
        not is_nil(Ledger.candidate_due(config.scope, config.inbox, now)) or
          not is_nil(Ledger.arrival_due(config.scope, config.inbox, checkpoint, version, now))
      else
        _ -> false
      end

    action_due or inbox_due
  end

  defp utc(time), do: DateTime.from_unix!(DateTime.to_unix(time, :microsecond), :microsecond)
  defp more?({_, more}) when is_boolean(more), do: more
  defp more?(_), do: false
  defp status({result, more}) when is_boolean(more), do: status(result)

  defp status({:deferred, reason}) when is_atom(reason), do: :deferred

  defp status({:deferred, _, {:settlement_pending, _, _}}), do: :policy_unavailable

  defp status({:deferred, _, result}),
    do: if(inbox_failure?(result), do: status(result), else: :deferred)

  defp status(value)
       when value in [
              :idle,
              :kept,
              :done,
              :blocked,
              :unresolved,
              :existing,
              :skipped,
              :deferred,
              :settlement_pending
            ],
       do: value

  defp status({:error, :not_found}), do: :gmail_unavailable
  defp status({:error, reason}) when reason in @fixed_errors, do: reason
  defp status(_), do: :worker_unavailable

  defp report_status({result, more}) when is_boolean(more), do: report_status(result)
  defp report_status({:deferred, reason}) when reason in @fixed_errors, do: reason
  defp report_status(result), do: status(result)

  defp report(config, value) do
    try do
      config.report.(value)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp protect(fun) do
    fun.()
  rescue
    _ -> {:error, :worker_unavailable}
  catch
    _, _ -> {:error, :worker_unavailable}
  end
end
