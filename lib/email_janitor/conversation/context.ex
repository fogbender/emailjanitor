defmodule EmailJanitor.Conversation.Context do
  @moduledoc "A trusted host capability. Never construct it from model fields or unauthenticated email headers."
  @derive {Inspect, only: [:inbox, :conversation_id]}
  @enforce_keys [:scope, :inbox, :conversation_id, :gmail, :model, :guard, :policy]
  defstruct @enforce_keys ++
              [
                request_evidence: nil,
                previous_request_id: nil,
                execution_options: [],
                planner: EmailJanitor.Conversation.Planner
              ]
end
