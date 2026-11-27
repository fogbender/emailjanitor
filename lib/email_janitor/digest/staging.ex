defmodule EmailJanitor.Digest.Staging do
  @moduledoc "Database-only staging and durable action confirmation; no Gmail fetches or full bodies."
  import Ecto.Query
  alias EmailJanitor.Digest
  alias EmailJanitor.Digest.{Activity, Event, Staged, StagingMigration}
  alias EmailJanitor.Store.{Action, Mailbox, Scope}

  def install(%Scope{} = scope),
    do: Ecto.Migrator.up(scope.repo, 12, StagingMigration, prefix: scope.prefix, log: false)

  def stage(%Scope{} = scope, inbox_id, %Event{kind: :done} = event) do
    with {:ok, event} <-
           Event.new(
             event.source_id,
             event.message_id,
             :done,
             event.sender,
             event.subject,
             event.occurred_at
           ) do
      transaction(scope, inbox_id, fn ->
        if !scope.repo.exists?(confirmed(inbox_id, event.source_id, [event.message_id]),
             prefix: scope.prefix
           ) do
          row = %Staged{
            inbox_id: inbox_id,
            action_id: event.source_id,
            message_id: event.message_id,
            sender: event.sender,
            subject: event.subject,
            occurred_at: event.occurred_at
          }

          scope.repo.insert!(row, prefix: scope.prefix, on_conflict: :nothing)

          saved =
            scope.repo.get_by!(
              Staged,
              [inbox_id: inbox_id, action_id: event.source_id, message_id: event.message_id],
              prefix: scope.prefix
            )

          if {saved.sender, saved.subject} != {event.sender, event.subject},
            do: scope.repo.rollback(:digest_stage_conflict)
        end

        :ok
      end)
    else
      _ -> {:error, :invalid_digest_stage}
    end
  end

  def stage(_, _, _), do: {:error, :invalid_digest_stage}

  def confirm(%Scope{} = scope, inbox_id, action_id) do
    with {:ok, action_id} <- Ecto.UUID.cast(action_id) do
      transaction(scope, inbox_id, fn ->
        action =
          scope.repo.one(
            from(a in Action,
              where: a.inbox_id == ^inbox_id and a.id == ^action_id,
              lock: "FOR UPDATE"
            ),
            prefix: scope.prefix
          )

        case action do
          %Action{state: state} when state in [:intent, :unresolved] ->
            :ok

          %Action{state: state} when state in [:done, :restored, :cancelled] ->
            promote(scope, action)

          _ ->
            scope.repo.rollback(:unknown_digest_action)
        end
      end)
    else
      _ -> {:error, :invalid_digest_stage}
    end
  end

  defp promote(scope, action) do
    applied = action.applied_message_ids

    if Enum.uniq(applied) != applied or applied -- action.message_ids != [],
      do: scope.repo.rollback(:invalid_digest_stage)

    staged_query =
      from(s in Staged,
        where: s.inbox_id == ^action.inbox_id and s.action_id == ^action.id
      )

    staged = scope.repo.all(staged_query, prefix: scope.prefix) |> Map.new(&{&1.message_id, &1})

    already =
      scope.repo.all(
        from(a in confirmed(action.inbox_id, action.id, applied),
          select: a.message_id
        ),
        prefix: scope.prefix
      )

    if applied -- (Map.keys(staged) ++ already) != [],
      do: scope.repo.rollback(:missing_digest_stage)

    for id <- applied -- already do
      row = Map.fetch!(staged, id)

      {:ok, event} =
        Event.new(
          action.id,
          id,
          :done,
          row.sender,
          row.subject,
          action.dispatch_started_at || action.inserted_at
        )

      {:ok, _} = Digest.record(scope, action.inbox_id, event)
    end

    # Only this action's exact original targets have a durable terminal outcome.
    # Retain unrelated rows rather than claiming they were proved unapplied.
    scope.repo.delete_all(from(s in staged_query, where: s.message_id in ^action.message_ids),
      prefix: scope.prefix
    )

    :ok
  end

  defp confirmed(inbox_id, action_id, ids),
    do:
      from(a in Activity,
        where:
          a.inbox_id == ^inbox_id and a.source_id == ^action_id and a.kind == :done and
            a.message_id in ^ids
      )

  defp transaction(scope, inbox_id, fun) do
    case scope.repo.transaction(fn ->
           case scope.repo.one(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
                  prefix: scope.prefix
                ) do
             nil -> scope.repo.rollback(:unknown_digest_inbox)
             _ -> fun.()
           end
         end) do
      {:ok, :ok} ->
        :ok

      {:error, reason}
      when reason in [
             :unknown_digest_inbox,
             :unknown_digest_action,
             :invalid_digest_stage,
             :digest_stage_conflict,
             :missing_digest_stage
           ] ->
        {:error, reason}

      _ ->
        {:error, :digest_unavailable}
    end
  rescue
    _ -> {:error, :digest_unavailable}
  catch
    _, _ -> {:error, :digest_unavailable}
  end
end
