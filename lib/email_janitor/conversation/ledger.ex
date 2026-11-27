defmodule EmailJanitor.Conversation.Ledger do
  @moduledoc "Pins effect selection before execution without retaining a conversation transcript."
  import Ecto.Query
  alias EmailJanitor.Conversation.{Plan, Receipt, Reference}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def install(%Scope{} = scope),
    do:
      Ecto.Migrator.up(scope.repo, 8, EmailJanitor.Conversation.Migration,
        prefix: scope.prefix,
        log: false,
        telemetry_event: nil
      )

  def get(%Scope{} = scope, inbox_id, conversation_id, request_id) do
    scope.repo.one(
      from(r in Receipt,
        where:
          r.id == ^request_id and r.inbox_id == ^inbox_id and
            r.conversation_id == ^conversation_id
      ),
      prefix: scope.prefix,
      log: false,
      telemetry_event: nil
    )
  end

  def latest(%Scope{} = scope, inbox_id, conversation_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -604_800)

    scope.repo.one(
      from(r in Receipt,
        where:
          r.inbox_id == ^inbox_id and r.conversation_id == ^conversation_id and
            r.inserted_at >= ^cutoff,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
      ),
      prefix: scope.prefix,
      log: false,
      telemetry_event: nil
    )
  end

  def reserve(
        %Scope{} = scope,
        inbox_id,
        conversation_id,
        request_id,
        %Plan{} = plan,
        refs,
        guard
      ) do
    with {:ok, request_id} <- Ecto.UUID.cast(request_id),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         true <- plan.operation in [:answer, :done, :restore],
         true <-
           is_list(refs) and length(refs) <= 10 and
             Enum.all?(refs, &match?(%Reference{inbox_id: ^inbox_id}, &1)) do
      metadata = Enum.map(refs, &metadata/1)

      transaction(scope, fn ->
        lock_mailbox(scope, inbox_id)
        if guard.() != :ok, do: scope.repo.rollback(:connection_changed)

        case scope.repo.get(Receipt, request_id,
               prefix: scope.prefix,
               log: false,
               telemetry_event: nil
             ) do
          nil ->
            scope.repo.insert!(
              %Receipt{
                id: request_id,
                inbox_id: inbox_id,
                conversation_id: conversation_id,
                operation: plan.operation,
                preference_target: plan.preference_target,
                references: metadata
              },
              prefix: scope.prefix,
              log: false,
              telemetry_event: nil
            )

          %Receipt{inbox_id: ^inbox_id, conversation_id: ^conversation_id} = existing ->
            if existing.operation == plan.operation and
                 existing.preference_target == plan.preference_target and
                 existing.references == metadata,
               do: existing,
               else: scope.repo.rollback(:request_conflict)

          _ ->
            scope.repo.rollback(:request_conflict)
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def record_preference(scope, inbox_id, conversation_id, request_id, status, revision)
      when status in [:none, :updated, :unchanged, :failed] and
             (is_nil(revision) or is_integer(revision)) do
    update(scope, inbox_id, conversation_id, request_id, fn receipt ->
      if receipt.preference_status in [:updated, :unchanged],
        do: receipt,
        else:
          Ecto.Changeset.change(receipt, preference_status: status, preference_revision: revision)
    end)
  end

  @result_statuses ~w(done restored protected blocked unresolved unavailable unchanged)
  def record_result(scope, inbox_id, conversation_id, request_id, reference, status, effect_id)
      when status in @result_statuses do
    with true <- is_nil(effect_id) or match?({:ok, _}, Ecto.UUID.cast(effect_id)) do
      update(scope, inbox_id, conversation_id, request_id, fn receipt ->
        if not Enum.any?(receipt.references, &(&1["token"] == reference)),
          do: scope.repo.rollback(:invalid_reference)

        result = %{"reference" => reference, "status" => status, "effect_id" => effect_id}
        existing = Enum.find(receipt.results, &(&1["reference"] == reference))

        cond do
          existing &&
              existing["status"] in [
                "done",
                "restored",
                "protected",
                "blocked",
                "unresolved",
                "unchanged"
              ] ->
            receipt

          true ->
            Ecto.Changeset.change(receipt,
              results: Enum.reject(receipt.results, &(&1["reference"] == reference)) ++ [result]
            )
        end
      end)
    else
      _ -> {:error, :invalid_effect}
    end
  end

  def complete(scope, inbox_id, conversation_id, request_id),
    do:
      update(
        scope,
        inbox_id,
        conversation_id,
        request_id,
        &Ecto.Changeset.change(&1, completed: true)
      )

  def purge(scope, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -604_800)

    scope.repo.delete_all(from(r in Receipt, where: r.inserted_at < ^cutoff),
      prefix: scope.prefix,
      log: false,
      telemetry_event: nil
    )
  end

  defp update(scope, inbox_id, conversation_id, request_id, fun) do
    transaction(scope, fn ->
      lock_mailbox(scope, inbox_id)

      receipt =
        get(scope, inbox_id, conversation_id, request_id) || scope.repo.rollback(:unknown_request)

      case fun.(receipt) do
        %Ecto.Changeset{} = changes ->
          scope.repo.update!(changes, prefix: scope.prefix, log: false, telemetry_event: nil)

        %Receipt{} = receipt ->
          receipt
      end
    end)
  end

  defp lock_mailbox(scope, id) do
    scope.repo.one(from(m in Mailbox, where: m.id == ^id, lock: "FOR UPDATE"),
      prefix: scope.prefix,
      log: false,
      telemetry_event: nil
    ) || scope.repo.rollback(:unknown_inbox)
  end

  defp metadata(ref),
    do: %{
      "token" => ref.token,
      "message_id" => ref.message_id,
      "thread_id" => ref.thread_id,
      "action_id" => ref.action_id
    }

  defp transaction(scope, fun) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: scope.repo.transaction(fun, log: false, telemetry_event: nil)
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end
end
