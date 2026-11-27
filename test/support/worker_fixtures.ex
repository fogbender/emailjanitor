defmodule EmailJanitor.WorkerTest.Repo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.WorkerTest.Gmail do
  @behaviour EmailJanitor.Gmail
  alias EmailJanitor.Gmail.{HistoryBatch, ThreadSnapshot}
  def watch(_, _, options), do: watch_result(options, :watch)
  def renew_watch(_, _, options), do: watch_result(options, :renew)

  defp watch_result(options, kind) do
    Agent.get_and_update(options[:state], fn state ->
      result =
        if kind == :renew and options[:renew_error] do
          {:error, options[:renew_error]}
        else
          {:ok,
           %{history_id: state.watch_id, expires_at: DateTime.add(DateTime.utc_now(), 604_800)}}
        end

      {result, %{state | calls: state.calls ++ [kind]}}
    end)
  end

  def ingestion_batch(inbox, cursor, options) do
    if options[:history_expired],
      do: {:error, :history_expired},
      else: history_batch(inbox, cursor, options)
  end

  defp history_batch(_, cursor, options) do
    Agent.get_and_update(options[:state], fn state ->
      value = Map.get(state.arrivals, cursor, %{through: cursor, ids: []})

      result =
        {:ok,
         %HistoryBatch{
           from_id: cursor,
           through_id: value.through,
           started_at: DateTime.utc_now(),
           added_message_ids: value.ids,
           more?: false
         }}

      {result, %{state | calls: state.calls ++ [{:history, cursor}]}}
    end)
  end

  def thread_id(_, id, options) do
    Agent.get(options[:state], fn state ->
      case {options[:thread_id_error], Enum.find(state.messages, &(&1.id == id))} do
        {error, _} when not is_nil(error) -> {:error, error}
        {_, nil} -> {:error, :message_not_found}
        {_, message} -> {:ok, message.thread_id}
      end
    end)
  end

  def thread_snapshot(_, thread, options) do
    if hook = options[:snapshot_hook], do: hook.()

    Agent.get_and_update(options[:state], fn state ->
      result =
        cond do
          options[:snapshot_error] ->
            {:error, options[:snapshot_error]}

          thread in Keyword.get(options, :snapshot_outages, []) ->
            {:error, :gmail_unavailable}

          thread in Keyword.get(options, :snapshot_failures, []) ->
            {:error, :invalid_thread_snapshot}

          true ->
            {:ok, %ThreadSnapshot{thread_id: thread, fingerprint: state.revision}}
        end

      {result, %{state | calls: state.calls ++ [:snapshot]}}
    end)
  end

  def thread(_, thread, options) do
    Agent.get_and_update(options[:state], fn state ->
      count = Map.get(state, :full_thread_count, 0) + 1

      injected =
        if options[:full_thread_error_at] == count,
          do: Keyword.get(options, :full_thread_late_error, :thread_not_found)

      result =
        if injected || options[:full_thread_error],
          do: {:error, injected || options[:full_thread_error]},
          else:
            if(thread in Keyword.get(options, :thread_failures, []),
              do: {:error, Keyword.get(options, :thread_error, :invalid_thread)},
              else: {:ok, Enum.filter(state.messages, &(&1.thread_id == thread))}
            )

      {result,
       state
       |> Map.put(:calls, state.calls ++ [:full_thread])
       |> Map.put(:full_thread_count, count)}
    end)
  end

  def contacted(_, _, options),
    do: Agent.get(options[:state], &{:ok, Map.get(&1, :contacts, MapSet.new())})

  def history_id(_, options) do
    if hook = options[:history_hook], do: hook.()
    {:ok, "200"}
  end

  def remove_inbox(_, ids, options) do
    if hook = options[:before_mutation], do: hook.()

    Agent.get_and_update(options[:state], fn state ->
      messages =
        Enum.map(state.messages, fn message ->
          if message.id in ids,
            do: %{message | labels: List.delete(message.labels, "INBOX")},
            else: message
        end)

      result = if state.mutation == :timeout_after_apply, do: {:error, :timeout}, else: :ok
      {result, %{state | messages: messages, mutations: state.mutations ++ [ids]}}
    end)
  end

  def history(_, _, options) do
    Agent.get(options[:state], fn state ->
      {:ok,
       %{
         complete?: true,
         started_at: DateTime.utc_now(),
         history_id: "202",
         from_id: "200",
         added_message_ids: [],
         deleted_message_ids: [],
         events: state.evidence
       }}
    end)
  end
end

defmodule EmailJanitor.WorkerTest.Classifier do
  @behaviour EmailJanitor.Classifier
  def classify(messages, _instructions, options) do
    result =
      Agent.get_and_update(options[:state], fn state ->
        result =
          case if(
                 Enum.any?(
                   messages,
                   &(&1.thread_id in Keyword.get(options, :failed_threads, []))
                 ),
                 do: :rejected,
                 else: state.model
               ) do
            :unreadable ->
              {:keep, :unreadable_content}

            :error ->
              {:error, "PRIVATE_MODEL_ERROR_SENTINEL"}

            :invalid ->
              {:ok, %{}}

            :rejected ->
              {:error, :model_rejected}

            mode ->
              action = if mode == :keep, do: "keep", else: "done"
              category = if mode == :keep, do: "legitimate", else: "cold_outreach"

              {:ok,
               %{
                 "decisions" =>
                   Enum.map(options[:target_ids], fn id ->
                     %{
                       "message_id" => id,
                       "action" => action,
                       "confidence" => "high",
                       "category" => category
                     }
                   end)
               }}
          end

        {result, %{state | model_inputs: state.model_inputs ++ [Enum.map(messages, & &1.id)]}}
      end)

    if hook = options[:after_model], do: hook.()
    result
  end
end

defmodule EmailJanitor.WorkerTest.Policy do
  @behaviour EmailJanitor.Policy
  def reserve(state, inbox, id, ids, now),
    do:
      reserve(state, inbox, id, ids, now, %EmailJanitor.Policy.Admission{inbox_message_ids: ids})

  def reserve(state, _inbox, _id, _ids, _now, admission) do
    if hook = Agent.get(state, &Map.get(&1, :reserve_hook)), do: hook.()

    Agent.get_and_update(state, fn value ->
      result =
        cond do
          Map.get(value, :reserve_error, false) -> {:error, :temporary}
          value.block -> {:blocked, value.block}
          true -> :ok
        end

      {result, %{value | calls: value.calls ++ [{:reserve, admission.inbox_message_ids}]}}
    end)
  end

  def settle(state, _, _, _) do
    Agent.get_and_update(state, fn value ->
      result = if value.failures > 0, do: {:error, :temporary}, else: :ok
      {result, %{value | failures: max(value.failures - 1, 0), calls: value.calls ++ [:settle]}}
    end)
  end

  def retire_candidate(state, _, _, ids), do: retire(state, :retire_whole, ids)
  def retire_candidate_messages(state, _, _, ids), do: retire(state, :retire_exact, ids)

  defp retire(state, kind, ids) do
    Agent.get_and_update(state, fn value ->
      result = if Map.get(value, :retire_error, false), do: {:error, :temporary}, else: :ok
      {result, %{value | calls: value.calls ++ [{kind, ids}]}}
    end)
  end
end

defmodule EmailJanitor.WorkerTest.LegacyPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(_, _, _, _, _), do: :ok
  def settle(_, _, _, _), do: :ok
  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.WorkerTest.WholeOnlyPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(_, _, _, _, _), do: :ok
  def settle(_, _, _, _), do: :ok

  def retire_candidate(observer, _, _, ids),
    do:
      (
        send(observer, {:legacy_whole_retired, ids})
        :ok
      )
end

defmodule EmailJanitor.WorkerTest.FreshPolicy do
  @behaviour EmailJanitor.Policy
  alias EmailJanitor.Policy

  def reserve(ctx, box, id, ids, now),
    do: reserve(ctx, box, id, ids, now, %Policy.Admission{inbox_message_ids: ids})

  def reserve(ctx, box, id, ids, now, admission) do
    send(ctx.observer, {:fresh_policy, ctx.subject, :reserve, ids})
    Policy.reserve(ctx.base, box, id, ids, now, admission)
  end

  def settle(ctx, box, id, result) do
    send(ctx.observer, {:fresh_policy, ctx.subject, :settle, id})
    Policy.settle(ctx.base, box, id, result)
  end

  def retire_candidate(ctx, box, id, ids) do
    send(ctx.observer, {:fresh_policy, ctx.subject, :retire, ids})
    Policy.retire_candidate(ctx.base, box, id, ids)
  end

  def retire_candidate_messages(ctx, box, id, ids) do
    send(ctx.observer, {:fresh_policy, ctx.subject, :retire_exact, ids})
    Policy.retire_candidate_messages(ctx.base, box, id, ids)
  end
end
