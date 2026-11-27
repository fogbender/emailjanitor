defmodule EmailJanitor.Gmail.ThreadSnapshot do
  @moduledoc "Body-free provider thread revision; never reconciliation or cleanup authority."
  @enforce_keys [:thread_id, :fingerprint]
  defstruct @enforce_keys
end
