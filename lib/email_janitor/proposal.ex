defmodule EmailJanitor.Proposal do
  @moduledoc "Body-free reviewed mutation preconditions; a proposal never grants Gmail authority."
  @enforce_keys [:thread_id, :message_ids, :fingerprint, :instruction_version, :category]
  defstruct [
    :thread_id,
    :message_ids,
    :fingerprint,
    :instruction_version,
    :category,
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
end
