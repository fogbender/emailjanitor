defmodule EmailJanitor.Executor do
  @moduledoc "Recheck a proposal, persist an intent, and mutate exact IDs once. Ambiguity never causes a retry."
  alias EmailJanitor.{Identity, Inbox, Message, Owner, Proposal, Safeguards, Store}

  def execute(scope, %Inbox{} = inbox, %Proposal{} = proposal, {gmail, options}) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: Owner.run(fn -> do_execute(scope, inbox, proposal, gmail, options) end)
  end

  defp do_execute(scope, inbox, proposal, gmail, options) do
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
         {:ok, {status, action}} <- Store.intent(scope, inbox.id, proposal, history_id) do
      case status do
        :existing -> existing(scope, inbox, action)
        :created -> apply_intent(scope, inbox, action, gmail, options)
      end
    else
      false -> {:skip, :proposal_changed}
      {:keep, reason} -> {:skip, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :gmail_unavailable}
    end
  end

  defp apply_intent(scope, inbox, action, gmail, options) do
    # Any error after sending is ambiguous: retain the intent for history-based
    # reconciliation. Repeating execute cannot issue the mutation a second time.
    Owner.bounded(fn ->
      case Store.begin_dispatch(scope, inbox.id, action.id, action.owner_token) do
        :ok ->
          dispatch(scope, inbox, action, gmail, options)

        {:error, _} = error ->
          Store.cancel_prepared(scope, inbox.id, action.id, action.owner_token)
          error
      end
    end)
  end

  defp dispatch(scope, inbox, action, gmail, options) do
    case safe(fn -> gmail.remove_inbox(inbox.id, action.message_ids, options) end) do
      :ok ->
        :ok = Store.transition(scope, inbox.id, action.id, :intent, :done)
        {:done, action.id}

      _ ->
        :ok = Store.transition(scope, inbox.id, action.id, :intent, :unresolved)
        {:unresolved, action.id}
    end
  end

  @doc "Recover an orphan before fetching fresh Gmail history for a dead owner's sent request."
  def recover(scope, inbox, action_id), do: Store.recover(scope, inbox.id, action_id)

  defp existing(scope, inbox, %{state: :intent} = action) do
    case recover(scope, inbox, action.id) do
      {:ok, {state, _}} -> {:existing, action.id, state}
      _ -> {:existing, action.id, :intent}
    end
  end

  defp existing(_, _, action), do: {:existing, action.id, action.state}

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
