defmodule EmailJanitor.Proposal do
  @moduledoc "Body-free reviewed mutation preconditions; a proposal never grants Gmail authority."
  @enforce_keys [:thread_id, :message_ids, :fingerprint, :instruction_version, :category]
  defstruct [:thread_id, :message_ids, :fingerprint, :instruction_version, :category]
end
