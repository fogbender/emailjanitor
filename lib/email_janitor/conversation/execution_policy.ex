defmodule EmailJanitor.Conversation.ExecutionPolicy do
  @moduledoc "Bind exact cleanup effects to a conversation request in the same admission transaction."
  @behaviour EmailJanitor.Policy
  alias EmailJanitor.{Policy}
  alias EmailJanitor.Conversation.Ledger

  def new(base, scope, inbox_id, receipt) do
    %Policy{
      adapter: __MODULE__,
      context: %{
        base: base,
        scope: scope,
        inbox_id: inbox_id,
        request_id: receipt.id,
        owner_token: receipt.owner_token
      }
    }
  end

  def reserve(context, inbox, action, ids, now),
    do: reserve(context, inbox, action, ids, now, %Policy.Admission{inbox_message_ids: ids})

  def reserve(context, inbox, action, ids, now, admission) do
    with true <- inbox == context.inbox_id,
         :ok <- Policy.reserve(context.base, inbox, action, ids, now, admission),
         :ok <-
           Ledger.bind_action(
             context.scope,
             inbox,
             context.request_id,
             context.owner_token,
             action,
             ids
           ),
         do: :ok
  end

  def settle(context, inbox, action, result),
    do: Policy.settle(context.base, inbox, action, result)

  def retire_candidate(context, inbox, id, ids),
    do: Policy.retire_candidate(context.base, inbox, id, ids)

  def retire_candidate_messages(context, inbox, id, ids),
    do: Policy.retire_candidate_messages(context.base, inbox, id, ids)
end
