defmodule EmailJanitor.Store do
  @moduledoc "Scoped durable intents and restoration history. No raw email or provider output is accepted."
  import Ecto.Query
  alias EmailJanitor.{Inbox, Proposal}
  alias EmailJanitor.Store.{Action, Mailbox, Migration, Scope}

  def install(%Scope{repo: repo, prefix: prefix}) do
    Ecto.Adapters.SQL.query!(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"), [], log: false)
    Ecto.Migrator.up(repo, 1, Migration, prefix: prefix, log: false)
  end

  def add_inbox(%Scope{} = scope, %Inbox{} = inbox) do
    scope.repo.insert(%Mailbox{id: inbox.id, address: inbox.address}, prefix: scope.prefix)
  end

  def instruction_version(%Scope{} = scope, inbox_id) do
    case scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix) do
      nil -> {:error, :unknown_inbox}
      mailbox -> {:ok, mailbox.instruction_version}
    end
  end

  def intent(%Scope{} = scope, inbox_id, %Proposal{} = proposal, history_id)
      when is_binary(history_id) do
    true = Regex.match?(~r/\A[0-9]{1,32}\z/, history_id)

    record = %Action{
      id: Ecto.UUID.generate(),
      inbox_id: inbox_id,
      thread_id: proposal.thread_id,
      message_ids: proposal.message_ids,
      fingerprint: proposal.fingerprint,
      history_id: history_id,
      instruction_version: proposal.instruction_version,
      category: proposal.category,
      state: :intent
    }

    scope.repo.transaction(fn ->
      # Serialize reservations even for different reviews of the same message.
      # Label/prompt changes must never bypass an earlier ambiguous mutation.
      mailbox =
        scope.repo.one!(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
          prefix: scope.prefix
        )

      if mailbox.instruction_version != proposal.instruction_version,
        do: scope.repo.rollback(:proposal_changed)

      existing =
        scope.repo.one(
          from(a in Action,
            where:
              a.inbox_id == ^inbox_id and a.state in [:intent, :unresolved, :done, :restored] and
                fragment("? && ?::text[]", a.message_ids, ^proposal.message_ids),
            order_by: [asc: a.inserted_at],
            limit: 1
          ),
          prefix: scope.prefix
        )

      if existing do
        {:existing, existing}
      else
        {:created, scope.repo.insert!(record, prefix: scope.prefix)}
      end
    end)
  end

  def get(%Scope{} = scope, inbox_id, id) do
    scope.repo.one(from(a in Action, where: a.id == ^id and a.inbox_id == ^inbox_id),
      prefix: scope.prefix
    )
  end

  def transition(%Scope{} = scope, inbox_id, id, from_state, to_state)
      when {from_state, to_state} in [
             intent: :done,
             intent: :unresolved,
             intent: :cancelled,
             unresolved: :done,
             unresolved: :restored,
             unresolved: :cancelled,
             done: :restored
           ] do
    {count, _} =
      scope.repo.update_all(
        from(a in Action,
          where: a.id == ^id and a.inbox_id == ^inbox_id and a.state == ^from_state
        ),
        [set: [state: to_state, updated_at: DateTime.utc_now()]],
        prefix: scope.prefix
      )

    if count == 1, do: :ok, else: {:error, :state_changed}
  end

  def restored_ids(%Scope{} = scope, inbox_id) do
    scope.repo.all(
      from(a in Action,
        where: a.inbox_id == ^inbox_id and a.state == :restored,
        select: a.message_ids
      ),
      prefix: scope.prefix
    )
    |> List.flatten()
    |> MapSet.new()
  end
end
