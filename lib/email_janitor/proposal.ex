defmodule EmailJanitor.Proposal do
  @moduledoc "Body-free reviewed mutation preconditions; a proposal never grants Gmail authority."
  @enforce_keys [:thread_id, :message_ids, :fingerprint, :instruction_version, :category]
  defstruct [
    :thread_id,
    :message_ids,
    :fingerprint,
    :instruction_version,
    :category,
    :message_categories,
    :review_started_at,
    :inbox_message_ids,
    :evaluated_message_ids
  ]

  # Nil preserves the original whole-INBOX proposal contract for existing hosts.
  def inbox_ids(%__MODULE__{} = proposal),
    do:
      if(is_nil(proposal.inbox_message_ids),
        do: proposal.message_ids,
        else: proposal.inbox_message_ids
      )

  def evaluated_ids(%__MODULE__{} = proposal),
    do:
      if(is_nil(proposal.evaluated_message_ids),
        do: proposal.message_ids,
        else: proposal.evaluated_message_ids
      )

  def categories(%__MODULE__{message_categories: nil} = proposal),
    do: Map.new(proposal.message_ids, &{&1, proposal.category})

  def categories(%__MODULE__{} = proposal), do: proposal.message_categories

  def batch_category(categories) do
    case Enum.uniq(Map.values(categories)) do
      [category] -> category
      [_ | _] -> :mixed
    end
  end

  def valid_categories?(%__MODULE__{} = proposal) do
    categories = categories(proposal)

    is_map(categories) and Enum.sort(Map.keys(categories)) == Enum.sort(proposal.message_ids) and
      Enum.all?(Map.values(categories), &(&1 in [:cold_outreach, :user_instruction])) and
      batch_category(categories) == proposal.category
  end
end
