defmodule EmailJanitor.Executor do
  @moduledoc "Recheck a proposal, persist an intent, and mutate exact IDs once. Ambiguity never causes a retry."
  alias EmailJanitor.{Identity, Inbox, Message, Policy, Proposal, Safeguards, Store}

  def execute(scope, %Inbox{} = inbox, %Proposal{} = proposal, {gmail, options}, opts \\ []) do
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
         {:ok, {status, action}} <- Store.intent(scope, inbox.id, proposal, history_id, opts) do
      case status do
        :existing -> existing(inbox, action, opts)
        :created -> apply_intent(scope, inbox, action, gmail, options, opts)
        :blocked -> {:blocked, action}
      end
    else
      false -> {:skip, :proposal_changed}
      {:keep, reason} -> {:skip, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :gmail_unavailable}
    end
  end

  defp apply_intent(scope, inbox, action, gmail, options, opts) do
    # Any error after sending is ambiguous: retain the intent for history-based
    # reconciliation. Repeating execute cannot issue the mutation a second time.
    case safe(fn -> gmail.remove_inbox(inbox.id, action.message_ids, options) end) do
      :ok ->
        :ok = Store.transition(scope, inbox.id, action.id, :intent, :done)

        settle(
          inbox,
          action.id,
          {:confirmed, action.message_ids},
          {:done, action.id},
          :done,
          opts
        )

      _ ->
        :ok = Store.transition(scope, inbox.id, action.id, :intent, :unresolved)
        settle(inbox, action.id, :unresolved, {:unresolved, action.id}, :unresolved, opts)
    end
  end

  def reconcile(scope, inbox, action_id, history, opts \\ []) do
    case Store.reconcile(scope, inbox.id, action_id, history) do
      {:ok, {state, result}} = resolved ->
        settle(
          inbox,
          action_id,
          {:reconciled, result.removed_ids, result.retry_ids},
          resolved,
          state,
          opts
        )

      error ->
        error
    end
  end

  @doc "Retry host settlement from durable outcomes without issuing any Gmail request."
  def settle_action(scope, inbox, action_id, opts \\ []) do
    case Store.get(scope, inbox.id, action_id) do
      nil -> {:error, :unknown_action}
      action -> existing(inbox, action, opts)
    end
  end

  defp existing(inbox, action, opts) do
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

    if result == :in_flight,
      do: {:existing, action.id, action.state},
      else:
        settle(inbox, action.id, result, {:existing, action.id, action.state}, action.state, opts)
  end

  defp settle(inbox, id, result, success, state, opts) do
    case Policy.settle(Keyword.get(opts, :policy, Policy.unlimited()), inbox.id, id, result) do
      :ok -> success
      _ -> {:settlement_pending, id, state}
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
