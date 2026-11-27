defmodule EmailJanitor.Restore do
  @moduledoc """
  Explicit, exact-message restoration of confirmed Janitor suppressions.

  A UUID effect binds the original action and exact IDs. Protections become
  durable before dispatch and survive failure, so later classification cannot
  suppress a requested restoration. Ambiguous effects are never auto-dispatched
  again, including after process death. This does not blanket-restore an action.
  The trusted host supplies a bounded DB-only `authorize` callback and the
  current `expected_instruction_version`; disconnect must bump that version.
  """
  import Ecto.Query
  alias EmailJanitor.{Inbox, Owner, Store}
  alias EmailJanitor.Gmail.Parser
  alias EmailJanitor.Store.{Action, Mailbox}
  alias EmailJanitor.Restore.{Effect, Protection}

  @errors [
    :wrong_inbox,
    :authorization_required,
    :forbidden,
    :rate_limited,
    :gmail_unavailable,
    :connection_changed,
    :instructions_changed,
    :restore_pending,
    :unconfirmed_suppression,
    :invalid_restore_selection,
    :effect_conflict,
    :restore_unsupported,
    :dispatch_window_exhausted,
    :outer_transaction,
    :ownership_lost
  ]

  def install(scope), do: normalize_install(Store.install(scope))

  def apply(
        scope,
        %Inbox{} = inbox,
        effect_id,
        action_id,
        ids,
        {gmail, gmail_options},
        options \\ []
      ) do
    if scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      result =
        safe(fn ->
          with {:ok, effect_id} <- Ecto.UUID.cast(effect_id),
               {:ok, action_id} <- Ecto.UUID.cast(action_id),
               true <- valid_ids?(ids),
               authorize when is_function(authorize, 0) <-
                 Keyword.get(options, :authorize, fn -> :ok end),
               :ok <- authorized(authorize),
               {:ok, version} <- version(scope, inbox, options) do
            ids = Enum.sort(ids)

            case existing(scope, inbox, effect_id, action_id, ids) do
              :new ->
                Owner.run(fn ->
                  with {:ok, mutation} <- prepare(gmail, inbox.id, ids, gmail_options),
                       :ok <- Owner.dispatch_window(),
                       {:ok, effect} <-
                         intent(scope, inbox, effect_id, action_id, ids, version, authorize) do
                    dispatch(scope, inbox, effect, mutation, authorize)
                  end
                end)
                |> recover_result(scope, inbox, effect_id, action_id, ids)

              existing ->
                existing
            end
          else
            {:error, reason} when reason in @errors -> {:error, reason}
            _ -> {:error, :invalid_restore_selection}
          end
        end)

      result
    end
  end

  defp intent(scope, inbox, id, action_id, ids, version, authorize) do
    transaction(scope, fn ->
      mailbox = lock_mailbox(scope, inbox)
      check_version!(scope, mailbox, version)
      require_authorized!(scope, authorize)

      case existing(scope, inbox, id, action_id, ids) do
        :new -> :ok
        result -> scope.repo.rollback({:existing_result, result})
      end

      action =
        scope.repo.one(
          from(a in Action,
            where: a.id == ^action_id and a.inbox_id == ^inbox.id,
            lock: "FOR UPDATE"
          ),
          prefix: scope.prefix,
          log: false
        )

      unless match?(%Action{state: state} when state in [:done, :restored], action) and
               Enum.all?(ids, &(&1 in action.applied_message_ids)),
             do: scope.repo.rollback(:unconfirmed_suppression)

      stale_prepared(scope, inbox, ids)

      if scope.repo.exists?(
           from(e in Effect,
             where:
               e.inbox_id == ^inbox.id and
                 e.state in [:intent, :unresolved] and
                 fragment("? && ?::text[]", e.message_ids, ^ids)
           ),
           prefix: scope.prefix,
           log: false
         ),
         do: scope.repo.rollback(:restore_pending)

      case Owner.dispatch_window() do
        :ok -> :ok
        _ -> scope.repo.rollback(:dispatch_window_exhausted)
      end

      now = clock(scope)

      effect =
        struct!(
          Effect,
          Map.merge(Owner.capture(), %{
            id: id,
            inbox_id: inbox.id,
            action_id: action_id,
            message_ids: ids,
            instruction_version: version,
            state: :intent,
            lease_expires_at: DateTime.add(now, 120),
            inserted_at: now,
            updated_at: now
          })
        )

      effect = scope.repo.insert!(effect, prefix: scope.prefix, log: false)

      scope.repo.insert_all(
        Protection,
        Enum.map(ids, &%{inbox_id: inbox.id, message_id: &1, effect_id: id}),
        prefix: scope.prefix,
        log: false,
        conflict_target: [:inbox_id, :message_id],
        on_conflict: :nothing
      )

      effect
    end)
  end

  defp dispatch(scope, inbox, effect, mutation, authorize) do
    result =
      Owner.bounded(fn ->
        case begin_dispatch(scope, inbox, effect, authorize) do
          :ok ->
            case safe(mutation) do
              :ok ->
                case finish(scope, effect, :done) do
                  :ok -> {:done, effect.id}
                  _ -> {:unresolved, effect.id}
                end

              _ ->
                finish(scope, effect, :unresolved)
                {:unresolved, effect.id}
            end

          {:error, reason} ->
            cancel_prepared(scope, inbox, effect)
            {:error, reason}
        end
      end)

    case result do
      {:error, :dispatch_window_exhausted} ->
        cancel_prepared(scope, inbox, effect)
        result

      result ->
        result
    end
  end

  defp begin_dispatch(scope, inbox, effect, authorize) do
    case transaction(scope, fn ->
           mailbox = lock_mailbox(scope, inbox)
           check_version!(scope, mailbox, effect.instruction_version)

           current =
             scope.repo.one(
               from(e in Effect,
                 where: e.id == ^effect.id,
                 lock: "FOR UPDATE"
               ),
               prefix: scope.prefix,
               log: false
             )

           require_authorized!(scope, authorize)

           unless current && current.state == :intent && is_nil(current.dispatch_started_at) &&
                    current.owner_token == effect.owner_token && Owner.owns?(current),
                  do: scope.repo.rollback(:ownership_lost)

           if DateTime.compare(current.lease_expires_at, clock(scope)) != :gt,
             do: scope.repo.rollback(:ownership_lost)

           case Owner.dispatch_window() do
             :ok -> :ok
             _ -> scope.repo.rollback(:dispatch_window_exhausted)
           end

           scope.repo.update!(Ecto.Changeset.change(current, dispatch_started_at: clock(scope)),
             prefix: scope.prefix,
             log: false
           )

           :ok
         end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp finish(scope, effect, state) do
    {count, _} =
      scope.repo.update_all(
        from(e in Effect,
          where:
            e.id == ^effect.id and e.inbox_id == ^effect.inbox_id and
              e.owner_token == ^effect.owner_token and e.state == :intent and
              not is_nil(e.dispatch_started_at)
        ),
        [set: [state: state, updated_at: clock(scope)]],
        prefix: scope.prefix,
        log: false
      )

    if count == 1, do: :ok, else: {:error, :ownership_lost}
  end

  defp cancel_prepared(scope, inbox, effect) do
    transaction(scope, fn ->
      lock_mailbox(scope, inbox)

      current =
        scope.repo.one(
          from(e in Effect,
            where: e.id == ^effect.id,
            lock: "FOR UPDATE"
          ),
          prefix: scope.prefix,
          log: false
        )

      if current && current.state == :intent && is_nil(current.dispatch_started_at) &&
           (Owner.owns?(current) || Owner.proof(current) == :dead) do
        scope.repo.update!(Ecto.Changeset.change(current, state: :cancelled),
          prefix: scope.prefix,
          log: false
        )
      end

      :ok
    end)
  end

  defp existing(scope, inbox, id, action_id, ids) do
    case scope.repo.get(Effect, id, prefix: scope.prefix, log: false) do
      nil ->
        :new

      %Effect{inbox_id: box, action_id: action, message_ids: bound} = effect
      when box == inbox.id and action == action_id and bound == ids ->
        effect =
          if effect.state == :intent && is_nil(effect.dispatch_started_at) &&
               Owner.proof(effect) == :dead do
            cancel_prepared(scope, inbox, effect)
            scope.repo.get!(Effect, id, prefix: scope.prefix, log: false)
          else
            effect
          end

        state =
          if effect.state == :intent && not is_nil(effect.dispatch_started_at),
            do: :unresolved,
            else: effect.state

        {:existing, state, id}

      _ ->
        {:error, :effect_conflict}
    end
  end

  # A proven-dead owner with no dispatch marker cannot have sent this effect.
  # Release only that no-wire reservation, never a dispatched/unknown effect.
  defp stale_prepared(scope, inbox, ids) do
    rows =
      scope.repo.all(
        from(e in Effect,
          where:
            e.inbox_id == ^inbox.id and
              e.state == :intent and is_nil(e.dispatch_started_at) and
              fragment("? && ?::text[]", e.message_ids, ^ids),
          lock: "FOR UPDATE"
        ),
        prefix: scope.prefix,
        log: false
      )

    for effect <- rows, Owner.proof(effect) == :dead do
      scope.repo.update!(Ecto.Changeset.change(effect, state: :cancelled),
        prefix: scope.prefix,
        log: false
      )
    end

    :ok
  end

  defp recover_result({:error, _} = error, scope, inbox, id, action_id, ids) do
    case scope.repo.get(Effect, id, prefix: scope.prefix, log: false) do
      %Effect{inbox_id: box, action_id: action, message_ids: bound} = effect
      when box == inbox.id and action == action_id and bound == ids ->
        cond do
          effect.state == :done ->
            {:done, id}

          not is_nil(effect.dispatch_started_at) ->
            {:unresolved, id}

          true ->
            cancel_prepared(scope, inbox, effect)
            error
        end

      _ ->
        error
    end
  end

  defp recover_result(result, _, _, _, _, _), do: result

  defp prepare(adapter, inbox_id, ids, options) do
    with {:module, ^adapter} <- Code.ensure_loaded(adapter),
         true <- function_exported?(adapter, :prepare_add_inbox, 3) do
      case safe(fn -> adapter.prepare_add_inbox(inbox_id, ids, options) end) do
        {:ok, mutation} when is_function(mutation, 0) -> {:ok, mutation}
        {:error, reason} when reason in @errors -> {:error, reason}
        _ -> {:error, :gmail_unavailable}
      end
    else
      _ -> {:error, :restore_unsupported}
    end
  end

  defp lock_mailbox(scope, inbox) do
    mailbox =
      scope.repo.one(from(m in Mailbox, where: m.id == ^inbox.id, lock: "FOR UPDATE"),
        prefix: scope.prefix,
        log: false
      )

    unless mailbox && mailbox.address == inbox.address, do: scope.repo.rollback(:wrong_inbox)
    mailbox
  end

  defp check_version!(scope, mailbox, version) do
    if mailbox.instruction_version != version, do: scope.repo.rollback(:instructions_changed)
  end

  defp require_authorized!(scope, authorize) do
    case authorized(authorize) do
      :ok -> :ok
      {:error, reason} -> scope.repo.rollback(reason)
    end
  end

  defp authorized(fun) do
    case safe(fun) do
      :ok -> :ok
      _ -> {:error, :connection_changed}
    end
  end

  defp version(scope, inbox, options) do
    case Keyword.fetch(options, :expected_instruction_version) do
      {:ok, version} when is_integer(version) and version > 0 -> {:ok, version}
      :error -> Store.instruction_version(scope, inbox.id)
      _ -> {:error, :invalid_restore_selection}
    end
  end

  defp transaction(scope, fun) do
    case scope.repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, {:existing_result, result}} -> result
      {:error, reason} when reason in @errors -> {:error, reason}
      _ -> {:error, :restore_unavailable}
    end
  end

  defp clock(scope) do
    %{rows: [[now]]} =
      Ecto.Adapters.SQL.query!(scope.repo, "SELECT clock_timestamp()", [], log: false)

    now
  end

  defp valid_ids?(ids),
    do:
      is_list(ids) and length(ids) in 1..5 and
        Enum.uniq(ids) == ids and Enum.all?(ids, &Parser.valid_id?/1)

  defp normalize_install(value) when value in [:ok, :already_up], do: :ok
  defp normalize_install(_), do: {:error, :restore_unavailable}

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :restore_unavailable}
  catch
    _, _ -> {:error, :restore_unavailable}
  end
end
