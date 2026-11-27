defmodule EmailJanitor.Executor do
  @moduledoc "Recheck a proposal, persist an intent, and mutate exact IDs once. Ambiguity never causes a retry."
  alias EmailJanitor.{
    Gmail,
    Identity,
    Inbox,
    Message,
    Owner,
    Policy,
    Proposal,
    Reviewer,
    Safeguards,
    Store
  }

  def execute(scope, %Inbox{} = inbox, %Proposal{} = proposal, {gmail, options}, opts \\ []) do
    cond do
      scope.repo.in_transaction?() -> {:error, :outer_transaction}
      not valid_proposal_ids?(proposal) -> {:skip, :proposal_changed}
      true -> Owner.run(fn -> do_execute(scope, inbox, proposal, gmail, options, opts) end)
    end
  end

  @doc "Fetch and review a thread; known keep decisions retire obsolete pending work."
  def review(
        scope,
        %Inbox{} = inbox,
        thread_id,
        {gmail, options},
        classifier,
        instructions,
        version,
        opts \\ []
      ) do
    if scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      Owner.run(fn ->
        with {:ok, {context, current}} <-
               fetch_review(scope, inbox, thread_id, gmail, options, version, opts),
             {:ok, contacted} <- current_contacts(context, current, gmail, options) do
          restored = Store.restored_ids(scope, inbox.id)

          result =
            if exact_inbox_ids(current) == [],
              do: {:keep, :no_matching_inbox_messages},
              else:
                Reviewer.review(
                  current,
                  inbox,
                  contacted,
                  classifier,
                  instructions,
                  version,
                  restored,
                  context.opts
                )

          case result do
            {:ok, proposal} -> {:ok, %{proposal | review_started_at: context.started_at}}
            {:keep, :unreadable_content} -> result
            {:keep, reason} -> retire_keep(context, reason)
            result -> result
          end
        end
      end)
    end
  end

  defp fetch_review(scope, inbox, thread_id, gmail, options, version, opts) do
    with {:ok, {stored_version, started_at}} <- Store.review_snapshot(scope, inbox.id),
         true <- stored_version == version,
         {:ok, current} <- safe(fn -> gmail.thread(inbox.id, thread_id, options) end),
         true <-
           is_list(current) and Enum.all?(current, &match?(%Message{thread_id: ^thread_id}, &1)) do
      inbox_ids = exact_inbox_ids(current)

      opts =
        opts
        |> Keyword.put(:inbox_message_ids, inbox_ids)
        |> Keyword.put(:observed_message_ids, Enum.map(current, & &1.id))
        |> Keyword.put(
          :evaluated_message_ids,
          case Keyword.fetch(opts, :cleanup_target_ids) do
            {:ok, ids} when is_list(ids) -> Enum.filter(ids, &(&1 in inbox_ids))
            _ -> inbox_ids
          end
        )

      {:ok,
       {%{
          scope: scope,
          inbox: inbox,
          thread_id: thread_id,
          version: version,
          started_at: started_at,
          opts: opts
        }, current}}
    else
      false -> {:error, :proposal_changed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :gmail_unavailable}
    end
  end

  defp current_contacts(context, current, gmail, options) do
    if exact_inbox_ids(current) == [] do
      {:ok, MapSet.new()}
    else
      case Safeguards.evaluate(
             current,
             context.inbox,
             MapSet.new(),
             Store.restored_ids(context.scope, context.inbox.id)
           ) do
        {:keep, _} ->
          {:ok, MapSet.new()}

        {:classify, _} ->
          with {:ok, identity_keys} <- keys(current, context.inbox),
               do: safe(fn -> gmail.contacted(context.inbox.id, identity_keys, options) end)
      end
    end
  end

  defp retire_keep(context, reason) do
    case Store.retire_ineligible(
           context.scope,
           context.inbox.id,
           context.thread_id,
           context.version,
           context.started_at,
           context.opts
         ) do
      {:ok, :retired} -> {:keep, reason}
      error -> error
    end
  end

  defp do_execute(scope, inbox, proposal, gmail, options, opts) do
    opts = Keyword.put(opts, :cleanup_target_ids, Proposal.evaluated_ids(proposal))

    with {:ok, {context, current}} <-
           fetch_review(
             scope,
             inbox,
             proposal.thread_id,
             gmail,
             options,
             proposal.instruction_version,
             opts
           ),
         {:ok, contacted} <- current_contacts(context, current, gmail, options) do
      reason =
        if exact_inbox_ids(current) == [],
          do: {:keep, :no_matching_inbox_messages},
          else:
            Safeguards.evaluate(current, inbox, contacted, Store.restored_ids(scope, inbox.id))

      case reason do
        {:keep, reason} ->
          case retire_keep(context, reason) do
            {:keep, _} ->
              if Message.fingerprint(current) == proposal.fingerprint,
                do: {:skip, reason},
                else: {:skip, :proposal_changed}

            error ->
              error
          end

        {:classify, _} ->
          execute_current(
            scope,
            inbox,
            proposal,
            current,
            gmail,
            options,
            Keyword.put(opts, :review_started_at, context.started_at)
          )
      end
    else
      {:error, :proposal_changed} -> {:skip, :proposal_changed}
      error -> error
    end
  end

  defp execute_current(scope, inbox, proposal, current, gmail, options, opts) do
    with true <- Message.fingerprint(current) == proposal.fingerprint,
         true <- valid_proposal_ids?(proposal),
         true <- exact_inbox_ids(current) == Enum.sort(Proposal.inbox_ids(proposal)),
         {:ok, started_at} <- proposal_start(proposal, opts[:review_started_at]),
         opts = Keyword.put(opts, :review_started_at, started_at),
         {:ok, history_id} <- safe(fn -> gmail.history_id(inbox.id, options) end),
         {:ok, mutation} <- Gmail.prepare(gmail, inbox.id, proposal.message_ids, options),
         :ok <- Owner.dispatch_window(),
         {:ok, {status, action}} <- Store.intent(scope, inbox.id, proposal, history_id, opts) do
      case status do
        :existing -> existing(scope, inbox, action, opts)
        :created -> apply_intent(scope, inbox, action, mutation, opts)
        :blocked -> {:blocked, action}
      end
    else
      false -> {:skip, :proposal_changed}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :gmail_unavailable}
    end
  end

  defp valid_proposal_ids?(proposal) do
    done = proposal.message_ids
    evaluated = Proposal.evaluated_ids(proposal)
    inbox = Proposal.inbox_ids(proposal)

    Enum.all?([done, evaluated, inbox], fn ids ->
      is_list(ids) and ids != [] and length(ids) == length(Enum.uniq(ids)) and
        Enum.all?(ids, &is_binary/1)
    end) and Enum.all?(done, &(&1 in evaluated)) and Enum.all?(evaluated, &(&1 in inbox)) and
      Proposal.valid_categories?(proposal) and
      (is_nil(proposal.review_started_at) or match?(%DateTime{}, proposal.review_started_at))
  end

  defp proposal_start(%Proposal{review_started_at: nil}, current), do: {:ok, current}

  defp proposal_start(%Proposal{review_started_at: original}, current) do
    if DateTime.compare(original, current) in [:lt, :eq],
      do: {:ok, original},
      else: {:error, :proposal_changed}
  end

  defp apply_intent(scope, inbox, action, mutation, opts) do
    # Any error after sending is ambiguous: retain the intent for history-based
    # reconciliation. Repeating execute cannot issue the mutation a second time.
    result =
      Owner.bounded(fn ->
        case Store.begin_dispatch(scope, inbox.id, action.id, action.owner_token) do
          :ok ->
            dispatch(scope, inbox, action, mutation, opts)

          {:error, _} = error ->
            case Store.cancel_prepared(scope, inbox.id, action.id, action.owner_token) do
              :ok -> settle(scope, inbox, action.id, error, opts)
              _ -> error
            end
        end
      end)

    case result do
      {:error, :dispatch_window_exhausted} = error ->
        case Store.cancel_prepared(scope, inbox.id, action.id, action.owner_token) do
          :ok -> settle(scope, inbox, action.id, error, opts)
          _ -> error
        end

      other ->
        other
    end
  end

  defp dispatch(scope, inbox, action, mutation, opts) do
    case safe(mutation) do
      :ok ->
        :ok = Store.transition(scope, inbox.id, action.id, :intent, :done)
        settle(scope, inbox, action.id, {:done, action.id}, opts)

      _ ->
        :ok = Store.transition(scope, inbox.id, action.id, :intent, :unresolved)
        settle(scope, inbox, action.id, {:unresolved, action.id}, opts)
    end
  end

  def reconcile(scope, inbox, action_id, history, opts \\ []) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: do_reconcile(scope, inbox, action_id, history, opts)
  end

  defp do_reconcile(scope, inbox, action_id, history, opts) do
    case Store.reconcile(scope, inbox.id, action_id, history) do
      {:ok, {_state, _result}} = resolved ->
        settle(
          scope,
          inbox,
          action_id,
          resolved,
          opts
        )

      error ->
        error
    end
  end

  @doc "Retry host settlement from durable outcomes without issuing any Gmail request."
  def settle_action(scope, inbox, action_id, opts \\ []) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: settle(scope, inbox, action_id, nil, opts)
  end

  @doc "Recover an orphan and settle its durable result without issuing any Gmail request."
  def recover(scope, inbox, action_id, opts \\ []) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: do_recover(scope, inbox, action_id, opts)
  end

  defp do_recover(scope, inbox, action_id, opts) do
    case Store.recover(scope, inbox.id, action_id) do
      {:ok, _} = recovered -> settle(scope, inbox, action_id, recovered, opts)
      error -> error
    end
  end

  defp existing(scope, inbox, %{state: :intent} = action, opts) do
    Store.recover(scope, inbox.id, action.id)
    settle_action(scope, inbox, action.id, opts)
  end

  defp existing(scope, inbox, action, opts), do: settle_action(scope, inbox, action.id, opts)

  defp settle(scope, inbox, id, success, opts) do
    case Store.with_locked_action(scope, inbox.id, id, fn action ->
           result =
             case action.state do
               state when state in [:done, :restored, :cancelled] ->
                 {:reconciled, action.applied_message_ids,
                  action.message_ids -- action.applied_message_ids}

               :unresolved ->
                 :unresolved

               :intent ->
                 :in_flight
             end

           if result == :in_flight do
             {:existing, action.id, action.state}
           else
             case Policy.settle(
                    Keyword.get(opts, :policy, Policy.unlimited()),
                    inbox.id,
                    id,
                    result
                  ) do
               :ok -> success || {:existing, action.id, action.state}
               _ -> scope.repo.rollback({:settlement_pending, id, action.state})
             end
           end
         end) do
      {:ok, result} -> result
      {:error, {:settlement_pending, _, _} = pending} -> pending
      error -> error
    end
  end

  defp exact_inbox_ids(messages),
    do: messages |> Enum.filter(&Message.in_inbox?/1) |> Enum.map(& &1.id) |> Enum.sort()

  defp keys(messages, inbox) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case Identity.resolve(message, inbox) do
        {:ok, keys} -> {:cont, {:ok, Enum.uniq(keys ++ acc)}}
        _ -> {:halt, {:error, :protected_sender}}
      end
    end)
  end

  defp safe(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} = value -> value
      _ -> {:error, :gmail_unavailable}
    end
  rescue
    _ -> {:error, :gmail_unavailable}
  catch
    _, _ -> {:error, :gmail_unavailable}
  end
end
