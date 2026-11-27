defmodule EmailJanitor.Gmail.HistoryBatch do
  @moduledoc """
  One bounded ingestion page, complete only through its last closed history record.

  This is deliberately NOT reconciliation evidence: it has no `complete?` field.
  With more? true, immediately fetch again from through_id; no pagination token
  or giant all-history snapshot needs durable storage.
  """
  @enforce_keys [:from_id, :through_id, :started_at, :added_message_ids, :more?]
  defstruct @enforce_keys ++ [events: [], deleted_message_ids: []]
end
