defmodule EmailJanitor.Conversation.Outcome do
  @moduledoc "Factual replies derived from durable effects, never from a proposed completion claim."
  alias EmailJanitor.{Content, Preferences}
  alias EmailJanitor.Conversation.Receipt

  def render(%Receipt{} = receipt, %Preferences.Snapshot{} = snapshot) do
    if snapshot.inbox_id == receipt.inbox_id and snapshot.scope_prefix == receipt.__meta__.prefix,
      do: verified(receipt, snapshot),
      else: Content.new("I could not verify this request's inbox context.")
  end

  defp verified(receipt, snapshot) do
    preferences = preference(receipt, snapshot)
    results = receipt.results
    done = Enum.count(results, &(&1["status"] == "done"))
    restored = Enum.count(results, &(&1["status"] == "restored"))
    blocked = Enum.count(results, &(&1["status"] == "blocked"))
    protected = Enum.count(results, &(&1["status"] == "protected"))
    handled_elsewhere = Enum.count(results, &(&1["status"] == "handled_elsewhere"))
    deferred = Enum.count(results, &(&1["status"] == "deferred"))
    missing = max(0, length(receipt.references) - length(results))

    uncertain =
      Enum.count(results, &(&1["status"] == "unresolved")) +
        if(receipt.completed, do: missing, else: 0)

    awaiting = if receipt.completed, do: 0, else: missing
    unavailable = Enum.count(results, &(&1["status"] == "unavailable"))
    unchanged = Enum.count(results, &(&1["status"] == "unchanged"))
    not_found = Enum.count(results, &(&1["status"] == "missing"))
    unsupported = Enum.count(results, &(&1["status"] == "unsupported"))

    [
      preferences,
      if(done > 0, do: "I marked #{count(done)} Done."),
      if(restored > 0,
        do:
          "I returned #{count(restored)} to the inbox and protected them from automatic cleanup."
      ),
      if(blocked > 0,
        do:
          "#{count(blocked)} remain in the inbox because of the free-plan limit. Unlimited cleanup is $3/month."
      ),
      if(protected > 0,
        do: "I left #{count(protected)} unchanged because a mailbox safeguard applies."
      ),
      if(uncertain > 0,
        do:
          "The result for #{count(uncertain)} is uncertain. I will not repeat that Gmail request automatically."
      ),
      if(awaiting > 0, do: "I haven't confirmed the result for #{count(awaiting)} yet."),
      if(unavailable > 0,
        do: "I could not finish processing #{count(unavailable)}. Please try again."
      ),
      if(not_found > 0, do: "#{count(not_found)} could no longer be found."),
      if(unsupported > 0,
        do:
          "I could not restore #{count(unsupported)} because restoration is unavailable for this request."
      ),
      if(handled_elsewhere > 0,
        do:
          "Another Janitor action already handled #{count(handled_elsewhere)}. I did not send another Gmail request."
      ),
      if(deferred > 0,
        do:
          "I deferred #{count(deferred)} while another action was processed; this request did not change them."
      ),
      if(unchanged > 0, do: "#{count(unchanged)} needed no inbox change.")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "No email or instruction changes were made."
      parts -> Enum.join(parts, " ")
    end
    |> Content.new()
  end

  defp preference(%{preference_status: :failed}, _),
    do: "I could not confirm your instruction update. Please send that instruction again."

  defp preference(%{preference_status: :pending}, _),
    do: "An instruction change is still being verified; I cannot confirm its outcome yet."

  defp preference(%{preference_status: status} = receipt, snapshot)
       when status in [:updated, :unchanged] do
    current =
      if receipt.preference_target == :all,
        do: snapshot.global_revision,
        else: snapshot.local_revision

    scope = if receipt.preference_target == :all, do: "all your inboxes", else: "this inbox"

    cond do
      receipt.preference_revision != current ->
        "The instructions from this request have since been changed."

      status == :updated ->
        "I updated the instructions for #{scope}. You can correct them here at any time."

      true ->
        "The instructions for #{scope} already match that correction."
    end
  end

  defp preference(_, _), do: nil
  defp count(1), do: "1 email"
  defp count(n), do: "#{n} emails"
end
