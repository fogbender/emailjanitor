defmodule EmailJanitor.Conversation.Ledger do
  @moduledoc "Pins effect selection before execution without retaining a conversation transcript."
  import Ecto.Query
  alias EmailJanitor.Owner
  alias EmailJanitor.Conversation.{Plan, Receipt, Reference}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def install(%Scope{} = scope) do
    for {version, module} <- [
          {8, EmailJanitor.Conversation.Migration},
          {9, EmailJanitor.Conversation.OwnershipMigration}
        ] do
      Ecto.Migrator.up(scope.repo, version, module,
        prefix: scope.prefix,
        log: false,
        telemetry_event: nil
      )
    end
  end

  def get(%Scope{} = scope, inbox_id, conversation_id, request_id) do
    cutoff = cutoff()

    scope.repo.one(
      from(r in Receipt,
        where:
          r.id == ^request_id and r.inbox_id == ^inbox_id and
            r.conversation_id == ^conversation_id and r.inserted_at >= ^cutoff
      ),
      prefix: scope.prefix,
      log: false,
      telemetry_event: nil
    )
  end

  def latest(%Scope{} = scope, inbox_id, conversation_id, excluded_id \\ nil) do
    cutoff = DateTime.add(DateTime.utc_now(), -604_800)

    query =
      from(r in Receipt,
        where:
          r.inbox_id == ^inbox_id and r.conversation_id == ^conversation_id and
            r.inserted_at >= ^cutoff,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
      )

    query = if excluded_id, do: from(r in query, where: r.id != ^excluded_id), else: query

    scope.repo.one(
      query,
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
             Enum.all?(refs, &match?(%Reference{inbox_id: ^inbox_id}, &1)),
         tokens = Enum.map(refs, & &1.token),
         true <- length(Enum.uniq(tokens)) == length(tokens),
         true <- is_list(plan.references) and length(plan.references) <= 5,
         true <- length(Enum.uniq(plan.references)) == length(plan.references),
         true <- Enum.all?(plan.references, &(&1 in tokens)),
         true <- plan.operation != :answer or plan.references == [],
         true <- plan.operation == :answer or length(plan.references) in 1..5,
         true <- plan.preference_target in [:none, :inbox, :all],
         true <-
           plan.search_complete == true or
             (plan.operation == :answer and plan.preference_target == :none) do
      selected = Enum.map(plan.references, fn token -> Enum.find(refs, &(&1.token == token)) end)
      metadata = Enum.map(selected, &metadata/1)

      transaction(scope, fn ->
        lock_mailbox(scope, inbox_id)
        if guard.() != :ok, do: scope.repo.rollback(:connection_changed)
        cutoff = cutoff()

        scope.repo.delete_all(
          from(r in Receipt, where: r.id == ^request_id and r.inserted_at < ^cutoff),
          prefix: scope.prefix,
          log: false,
          telemetry_event: nil
        )

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
                references: metadata,
                context_references: Enum.map(refs, &metadata/1),
                search_complete: plan.search_complete,
                preference_status: if(plan.preference_target == :none, do: :none, else: :pending)
              }
              |> struct(Owner.capture()),
              prefix: scope.prefix,
              log: false,
              telemetry_event: nil
            )

          %Receipt{inbox_id: ^inbox_id, conversation_id: ^conversation_id} = existing ->
            if existing.operation == plan.operation and
                 existing.preference_target == plan.preference_target and
                 Enum.sort_by(existing.references, & &1["token"]) ==
                   Enum.sort_by(metadata, & &1["token"]),
               do: own(scope, existing),
               else: scope.repo.rollback(:request_conflict)

          _ ->
            scope.repo.rollback(:request_conflict)
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defmodule ActionBinding do
    use Ecto.Schema
    @primary_key {:action_id, Ecto.UUID, autogenerate: false}
    schema "conversation_action_bindings" do
      field(:request_id, Ecto.UUID)
      field(:inbox_id, :string)
      field(:message_ids, {:array, :string})
    end
  end

  @doc "Called only by the trusted admission policy inside Store.intent's mailbox transaction."
  def bind_action(scope, inbox_id, request_id, owner_token, action_id, ids) do
    if not scope.repo.in_transaction?(),
      do: raise(ArgumentError, "binding requires admission transaction")

    receipt =
      scope.repo.get(Receipt, request_id, prefix: scope.prefix, log: false, telemetry_event: nil)

    with %Receipt{
           inbox_id: ^inbox_id,
           operation: :done,
           completed: false,
           owner_token: ^owner_token
         } <- receipt,
         true <- is_list(ids) and length(ids) in 1..5,
         true <-
           Enum.all?(ids, fn id -> Enum.any?(receipt.references, &(&1["message_id"] == id)) end) do
      scope.repo.insert!(
        %ActionBinding{
          action_id: action_id,
          request_id: request_id,
          inbox_id: inbox_id,
          message_ids: Enum.sort(ids)
        },
        prefix: scope.prefix,
        log: false,
        telemetry_event: nil
      )

      :ok
    else
      _ -> {:error, :conversation_changed}
    end
  end

  @doc "Actual request-bound Gmail outcome, independent of provider reads or the receipt owner's liveness."
  def action_result(scope, inbox_id, request_id, message_id) do
    action =
      scope.repo.one(
        from(b in ActionBinding,
          join: a in EmailJanitor.Store.Action,
          on: a.id == b.action_id,
          where:
            b.request_id == ^request_id and b.inbox_id == ^inbox_id and
              a.inbox_id == ^inbox_id and ^message_id in b.message_ids and
              (a.state in [:intent, :unresolved] or
                 (a.state in [:done, :restored] and ^message_id in a.applied_message_ids)),
          order_by: [desc: a.inserted_at],
          limit: 1,
          select: a
        ),
        prefix: scope.prefix,
        log: false,
        telemetry_event: nil
      )

    case action do
      %{state: state, applied_message_ids: ids, id: id} when state in [:done, :restored] ->
        if message_id in ids, do: {:done, id}, else: :none

      %{state: :intent, dispatch_started_at: nil, id: id} ->
        {:prepared, id}

      %{state: state, id: id} when state in [:intent, :unresolved] ->
        {:unresolved, id}

      _ ->
        :none
    end
  end

  def record_preference(scope, inbox_id, conversation_id, request_id, status, revision)
      when status in [:none, :updated, :unchanged, :failed] and
             (is_nil(revision) or is_integer(revision)) do
    update(scope, inbox_id, conversation_id, request_id, fn receipt ->
      valid =
        case status do
          :none -> receipt.preference_target == :none and is_nil(revision)
          :failed -> receipt.preference_target != :none and is_nil(revision)
          _ -> receipt.preference_target != :none and is_integer(revision) and revision >= 0
        end

      if not valid, do: scope.repo.rollback(:invalid_preference_result)

      if receipt.preference_status in [:updated, :unchanged],
        do: receipt,
        else:
          Ecto.Changeset.change(receipt, preference_status: status, preference_revision: revision)
    end)
  end

  @result_statuses ~w(done restored protected blocked unresolved unavailable unchanged missing)
  def record_result(scope, inbox_id, conversation_id, request_id, reference, status, effect_id)
      when status in @result_statuses do
    with true <- is_nil(effect_id) or match?({:ok, _}, Ecto.UUID.cast(effect_id)) do
      update(scope, inbox_id, conversation_id, request_id, fn receipt ->
        if not Enum.any?(receipt.references, &(&1["token"] == reference)),
          do: scope.repo.rollback(:invalid_reference)

        if receipt.operation == :answer or
             (status in ["done", "blocked"] and receipt.operation != :done) or
             (status == "restored" and receipt.operation != :restore),
           do: scope.repo.rollback(:invalid_effect)

        if status in ["done", "restored", "unresolved"] and is_nil(effect_id),
          do: scope.repo.rollback(:invalid_effect)

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
        fn receipt ->
          expected = Enum.map(receipt.references, & &1["token"]) |> Enum.sort()
          observed = Enum.map(receipt.results, & &1["reference"]) |> Enum.sort()

          if expected != observed or receipt.preference_status == :pending or
               Enum.any?(receipt.results, &(&1["status"] == "unavailable")),
             do: scope.repo.rollback(:effects_pending)

          Ecto.Changeset.change(receipt, completed: true)
        end
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

      if receipt.completed, do: scope.repo.rollback(:request_complete)
      if not Owner.owns?(receipt), do: scope.repo.rollback(:request_in_flight)

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

  defp own(_scope, %Receipt{completed: true} = receipt), do: receipt

  defp own(scope, receipt) do
    cond do
      Owner.owns?(receipt) ->
        receipt

      is_nil(receipt.owner_runtime) or Owner.proof(receipt) == :dead ->
        receipt
        |> Ecto.Changeset.change(Owner.capture())
        |> scope.repo.update!(prefix: scope.prefix, log: false, telemetry_event: nil)

      true ->
        scope.repo.rollback(:request_in_flight)
    end
  end

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -604_800)

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
