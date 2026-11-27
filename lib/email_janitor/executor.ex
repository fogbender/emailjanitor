defmodule EmailJanitor.Executor do
  @moduledoc "Recheck a proposal, persist an intent, and mutate exact IDs once. Ambiguity never causes a retry."
  alias EmailJanitor.{Gmail, Identity, Inbox, Message, Owner, Policy, Proposal, Safeguards, Store}

  def execute(scope, %Inbox{} = inbox, %Proposal{} = proposal, {gmail, options}, opts \\ []) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: Owner.run(fn -> do_execute(scope, inbox, proposal, gmail, options, opts) end)
  end

  defp do_execute(scope, inbox, proposal, gmail, options, opts) do
    with {:ok, version} <- Store.instruction_version(scope, inbox.id),
         true <- version == proposal.instruction_version,
         {:ok, current} <- safe(fn -> gmail.thread(inbox.id, proposal.thread_id, options) end),
         true <- Message.fingerprint(current) == proposal.fingerprint,
         {:ok, keys} <- keys(current, inbox),
         {:ok, contacted} <- safe(fn -> gmail.contacted(inbox.id, keys, options) end),
         {:classify, _} <-
           Safeguards.evaluate(current, inbox, contacted, Store.restored_ids(scope, inbox.id)),
         true <- exact_inbox_ids(current) == Enum.sort(proposal.message_ids),
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
      {:keep, reason} -> {:skip, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :gmail_unavailable}
    end
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
    settle(scope, inbox, action_id, nil, opts)
  end

  @doc "Recover an orphan and settle its durable result without issuing any Gmail request."
  def recover(scope, inbox, action_id, opts \\ []) do
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
