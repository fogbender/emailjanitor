defmodule EmailJanitor.Reviewer do
  @moduledoc "Apply safeguards before the tool-free classifier; produce only body-free results."
  alias EmailJanitor.{Classifier, Decision, Message, Proposal, Safeguards}

  def review(
        messages,
        inbox,
        contacted_keys,
        classifier,
        instructions,
        version,
        restored \\ MapSet.new(),
        opts \\ []
      ) do
    with {:ok, messages, masked?} <- select_targets(messages, opts),
         {:classify, _} <- Safeguards.evaluate(messages, inbox, contacted_keys, restored),
         {:ok, classifier_messages} <- self_mail_filter(messages, opts),
         [_ | _] = targets <- Enum.filter(classifier_messages, &Message.cleanup_target?/1),
         {:ok, decisions} <-
           classify(masked?, classifier, classifier_messages, instructions, inbox) do
      done =
        decisions
        |> Enum.filter(fn {_, decision} ->
          decision.action == :done and decision.confidence == :high
        end)
        |> Enum.sort_by(&elem(&1, 0))

      case {Enum.uniq(Enum.map(messages, & &1.thread_id)), done} do
        {[thread_id], [{_, decision} | _]} ->
          {:ok,
           %Proposal{
             thread_id: thread_id,
             message_ids: Enum.map(done, &elem(&1, 0)),
             inbox_message_ids: inbox_ids(messages),
             evaluated_message_ids: targets |> Enum.map(& &1.id) |> Enum.sort(),
             fingerprint: Message.fingerprint(messages),
             instruction_version: version,
             category: decision.category
           }}

        {[_], []} ->
          {:keep, :classifier_kept}

        _ ->
          {:keep, :no_matching_inbox_messages}
      end
    else
      {:keep, _} = keep -> keep
      [] -> {:keep, :no_matching_inbox_messages}
      {:error, _} = error -> error
    end
  end

  defp self_mail_filter(messages, opts) do
    matcher = Keyword.get(opts, :self_mail, fn _ -> {:ok, false} end)

    if is_function(matcher, 1) do
      Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, kept} ->
        case matcher.(message.headers) do
          {:ok, true} -> {:cont, {:ok, kept}}
          {:ok, false} -> {:cont, {:ok, [message | kept]}}
          _ -> {:halt, {:error, :self_mail_unavailable}}
        end
      end)
      |> case do
        {:ok, kept} -> {:ok, Enum.reverse(kept)}
        error -> error
      end
    else
      {:error, :self_mail_unavailable}
    end
  rescue
    _ -> {:error, :self_mail_unavailable}
  catch
    _, _ -> {:error, :self_mail_unavailable}
  end

  defp select_targets(messages, opts) do
    case Keyword.fetch(opts, :cleanup_target_ids) do
      :error ->
        {:ok, messages, false}

      {:ok, ids} when is_list(ids) and length(ids) <= 200 ->
        if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256)) and
             length(Enum.uniq(ids)) == length(ids) do
          {:ok,
           Enum.map(messages, &%{&1 | cleanup_target: Message.in_inbox?(&1) and &1.id in ids}),
           true}
        else
          {:error, :invalid_targets}
        end

      _ ->
        {:error, :invalid_targets}
    end
  end

  defp classify(true, classifier, messages, instructions, inbox),
    do: Classifier.propose_targets(classifier, messages, instructions, inbox)

  defp classify(false, classifier, messages, instructions, inbox) do
    case Classifier.propose(classifier, messages, instructions, inbox) do
      {:ok, %Decision{} = decision} ->
        {:ok, Map.new(Enum.filter(messages, &Message.cleanup_target?/1), &{&1.id, decision})}

      other ->
        other
    end
  end

  defp inbox_ids(messages),
    do: messages |> Enum.filter(&Message.in_inbox?/1) |> Enum.map(& &1.id) |> Enum.sort()
end
