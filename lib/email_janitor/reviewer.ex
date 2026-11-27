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
        restored \\ MapSet.new()
      ) do
    with {:classify, _} <- Safeguards.evaluate(messages, inbox, contacted_keys, restored),
         {:ok, %Decision{action: :done, confidence: :high} = decision} <-
           Classifier.propose(classifier, messages, instructions) do
      ids = messages |> Enum.filter(&Message.in_inbox?/1) |> Enum.map(& &1.id) |> Enum.sort()

      case {Enum.uniq(Enum.map(messages, & &1.thread_id)), ids} do
        {[thread_id], [_ | _]} ->
          {:ok,
           %Proposal{
             thread_id: thread_id,
             message_ids: ids,
             fingerprint: Message.fingerprint(messages),
             instruction_version: version,
             category: decision.category
           }}

        _ ->
          {:keep, :no_matching_inbox_messages}
      end
    else
      {:keep, _} = keep -> keep
      {:ok, %Decision{}} -> {:keep, :classifier_kept}
      {:error, _} = error -> error
    end
  end
end
