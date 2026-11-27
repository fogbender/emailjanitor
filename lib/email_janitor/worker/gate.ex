defmodule EmailJanitor.Worker.Gate do
  @moduledoc false
  @behaviour EmailJanitor.Policy
  alias EmailJanitor.{Gmail.Ingestion, Policy}
  alias EmailJanitor.Worker.Ledger

  @impl true
  def reserve(context, inbox_id, action_id, ids, now),
    do: reserve(context, inbox_id, action_id, ids, now, %Policy.Admission{inbox_message_ids: ids})

  @impl true
  def reserve(
        %{config: config, proposal: proposal} = context,
        inbox_id,
        action_id,
        ids,
        now,
        admission
      ) do
    with :ok <- config.authorize.(), :ok <- proof(context) do
      result = Policy.reserve(config.policy, inbox_id, action_id, ids, now, admission)

      if result == :ok or match?({:blocked, _}, result) do
        generation =
          case context do
            %{source: source} -> source.generation
            %{eligible: eligible} -> eligible.generation
          end

        Ledger.record_candidate(
          config.scope,
          config.inbox,
          action_id,
          proposal,
          generation,
          now,
          Map.has_key?(context, :source)
        )
      end

      result
    else
      _ -> {:error, :connection_changed}
    end
  end

  defp proof(%{config: config, source: source, proposal: proposal, generation: generation}) do
    with :ok <- config.allow_recheck.(source.candidate_id),
         do: Ledger.authorize_candidate(config.scope, config.inbox, source, proposal, generation)
  end

  defp proof(%{config: config, eligible: eligible, proposal: proposal}),
    do: Ingestion.authorize_proposal(config.scope, config.inbox, eligible, proposal)

  @impl true
  def settle(%{config: config}, inbox_id, action_id, result),
    do: Policy.settle(config.policy, inbox_id, action_id, result)

  @impl true
  def retire_candidate(%{config: config}, inbox_id, id, ids) do
    with :ok <- Policy.retire_candidate(config.policy, inbox_id, id, ids),
         do: Ledger.retire_candidate(config.scope, config.inbox, id, ids)
  end
end
