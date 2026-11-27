defmodule EmailJanitor.DigestStagePolicy do
  @behaviour EmailJanitor.Policy
  alias EmailJanitor.{Digest, Store}
  alias EmailJanitor.Digest.Event

  def reserve(context, inbox, action, ids, now) do
    true = context.scope.repo.in_transaction?()
    nil = Store.get(context.scope, inbox, action)

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      header = Map.fetch!(context.headers, id)
      {:ok, event} = Event.new(action, id, :done, header.sender, header.subject, now)

      case Digest.stage(context.scope, inbox, event) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def settle(context, inbox, action, _result) do
    context.scope.repo.query!(
      "INSERT INTO #{context.scope.prefix}.digest_stage_host (action_id) VALUES ($1) ON CONFLICT DO NOTHING",
      [action],
      log: false
    )

    with :ok <- Digest.confirm_staged(context.scope, inbox, action) do
      if Agent.get(context.control, & &1), do: {:error, :retry_fixture}, else: :ok
    end
  end

  def retire_candidate(_, _, _, _), do: :ok
end
