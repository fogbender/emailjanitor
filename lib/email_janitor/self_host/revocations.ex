defmodule EmailJanitor.SelfHost.RevocationMigration do
  @moduledoc false
  use Ecto.Migration

  def up do
    drop(constraint(:self_host_bindings, :binding_state))

    create(
      constraint(:self_host_bindings, :binding_state,
        check:
          "state IN ('pending', 'active', 'disconnected', 'reauthorization_required', 'revoking', 'revocation_required')"
      )
    )

    create table(:self_host_revocations, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:request_id, :uuid, null: false)
      add(:google_subject, :text, null: false)
      add(:token_ciphertext, :binary)
      add(:state, :text, null: false)
      add(:outcome, :text, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:owner_token, :uuid)
      add(:owner_runtime, :text)
      add(:owner_host, :text)
      add(:owner_boot, :text)
      add(:owner_os_pid, :text)
      add(:owner_os_start, :text)
      add(:owner_beam_pid, :binary)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:self_host_revocations, [:google_subject]))

    create(
      constraint(:self_host_revocations, :revocation_state,
        check: "state IN ('pending', 'processing', 'manual_required', 'complete')"
      )
    )
  end

  def down do
    # Rolling back while a remote retirement is pending would permit relinking
    # an identity that an old worker could still revoke. Refuse that rollback.
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{prefix()}.self_host_revocations WHERE state <> 'complete') THEN RAISE EXCEPTION 'Pending Google revocation prevents rollback'; END IF; END $$"
    )

    drop(table(:self_host_revocations))
    drop(constraint(:self_host_bindings, :binding_state))

    create(
      constraint(:self_host_bindings, :binding_state,
        check: "state IN ('pending', 'active', 'disconnected', 'reauthorization_required')"
      )
    )
  end
end

defmodule EmailJanitor.SelfHost.Revocation do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:inbox_id, :string, autogenerate: false}
  @derive {Inspect, only: [:inbox_id, :state, :outcome]}
  schema "self_host_revocations" do
    field(:request_id, Ecto.UUID)
    field(:google_subject, :string)
    field(:token_ciphertext, :binary, redact: true)
    field(:grant_fingerprint, :binary, redact: true)
    field(:state, Ecto.Enum, values: [:pending, :processing, :manual_required, :complete])

    field(:outcome, Ecto.Enum,
      values: [
        :none,
        :unavailable,
        :refresh_token_invalid,
        :missing_token,
        :revoked,
        :credential_unusable,
        :operator_confirmed
      ]
    )

    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:owner_token, Ecto.UUID)
    field(:owner_runtime, :string)
    field(:owner_host, :string)
    field(:owner_boot, :string)
    field(:owner_os_pid, :string)
    field(:owner_os_start, :string)
    field(:owner_beam_pid, :binary, redact: true)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.SelfHost.Revocations do
  @moduledoc "Durable Google grant retirement; pending project/subject grants cannot be replaced."
  import Ecto.Query
  alias EmailJanitor.{Owner, SelfHost}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.{Binding, Grants, Refreshes, Revocation, Store}

  @owner_keys [
    :owner_token,
    :owner_runtime,
    :owner_host,
    :owner_boot,
    :owner_os_pid,
    :owner_os_start,
    :owner_beam_pid
  ]

  def install(%EmailJanitor.Store.Scope{repo: SelfHost.Repo, prefix: "ej_selfhost"} = scope),
    do:
      Ecto.Migrator.up(scope.repo, 103, SelfHost.RevocationMigration,
        prefix: scope.prefix,
        log: false
      )

  def install(_), do: {:error, :invalid_self_host_scope}

  @doc false
  def blocked?(scope, subject),
    do:
      scope.repo.exists?(
        from(r in Revocation, where: r.google_subject == ^subject and r.state != :complete),
        prefix: scope.prefix,
        log: false
      )

  @doc false
  def note_capture!(scope, inbox_id) do
    case scope.repo.get(Revocation, inbox_id, prefix: scope.prefix, log: false) do
      %Revocation{state: :manual_required} = row ->
        scope.repo.update!(Ecto.Changeset.change(row, request_id: Ecto.UUID.generate()),
          prefix: scope.prefix,
          log: false
        )

      _ ->
        :ok
    end
  end

  @doc false
  def stage_unbound!(scope, inbox_id, subject) do
    existing = scope.repo.get(Revocation, inbox_id, prefix: scope.prefix, log: false)

    if existing && existing.state != :complete do
      if existing.google_subject != subject, do: scope.repo.rollback(:connection_changed)
      :revoking
    else
      grant =
        Grants.next(scope, inbox_id) || scope.repo.rollback(:credential_retention_unavailable)

      row = existing || %Revocation{inbox_id: inbox_id}

      scope.repo.insert_or_update!(
        Ecto.Changeset.change(
          row,
          Map.merge(clear_owner(), %{
            request_id: Ecto.UUID.generate(),
            google_subject: subject,
            token_ciphertext: grant.token_ciphertext,
            grant_fingerprint: grant.fingerprint,
            state: :pending,
            outcome: :none,
            attempts: 0,
            next_attempt_at: nil
          })
        ),
        prefix: scope.prefix,
        log: false
      )

      :revoking
    end
  end

  @doc "Called only under the scoped mailbox lock in the disconnect transaction."
  def stage!(scope, binding, options \\ []) do
    if not scope.repo.in_transaction?(),
      do: raise(ArgumentError, "retirement requires mailbox transaction")

    Grants.retain_cipher!(scope, binding.id, binding.token_ciphertext)
    existing = scope.repo.get(Revocation, binding.id, prefix: scope.prefix, log: false)

    if existing && existing.state != :complete do
      if existing.google_subject != binding.google_subject,
        do: scope.repo.rollback(:connection_changed)

      existing = retain_current!(scope, existing)

      if existing.state == :manual_required do
        # A fresh callback invalidates an old local attestation's request ID.
        if Keyword.get(options, :new_grant, false) do
          scope.repo.update!(Ecto.Changeset.change(existing, request_id: Ecto.UUID.generate()),
            prefix: scope.prefix,
            log: false
          )
        end

        :revocation_required
      else
        :revoking
      end
    else
      grant = Grants.next(scope, binding.id)
      present = not is_nil(grant)

      unusable =
        not present and binding.state == :reauthorization_required and
          not Refreshes.uncertain?(scope, binding.id)

      fields = %{
        request_id: Ecto.UUID.generate(),
        google_subject: binding.google_subject,
        token_ciphertext: if(grant, do: grant.token_ciphertext),
        grant_fingerprint: if(grant, do: grant.fingerprint),
        state:
          cond do
            present -> :pending
            unusable -> :complete
            true -> :manual_required
          end,
        outcome:
          cond do
            present -> :none
            unusable -> :credential_unusable
            true -> :missing_token
          end,
        attempts: 0,
        next_attempt_at: nil
      }

      row = existing || %Revocation{inbox_id: binding.id}

      scope.repo.insert_or_update!(Ecto.Changeset.change(row, Map.merge(clear_owner(), fields)),
        prefix: scope.prefix,
        log: false
      )

      cond do
        present -> :revoking
        unusable -> :disconnected
        true -> :revocation_required
      end
    end
  end

  @doc """
  Trusted LOCAL operator attestation after removing ALL former Janitor access in
  the affected Google account. This does not verify or invoke Google. Never expose
  it to HTTP, a model, or an automatic retry. Exact request/subject matching and
  the mailbox lock prevent a stale confirmation from clearing a newer grant.
  """
  def confirm_manual(inbox_id, request_id, subject, :google_access_removed) do
    with {:ok, request_id} <- Ecto.UUID.cast(request_id),
         true <- is_binary(inbox_id) and is_binary(subject) do
      Store.transaction(fn scope ->
        Store.lock_mailbox(scope, inbox_id)
        row = scope.repo.get(Revocation, inbox_id, prefix: scope.prefix, log: false)
        binding = scope.repo.get(Binding, inbox_id, prefix: scope.prefix, log: false)

        unless row && binding && row.request_id == request_id && row.google_subject == subject &&
                 binding.google_subject == subject,
               do: scope.repo.rollback(:confirmation_changed)

        cond do
          row.state == :complete and row.outcome == :operator_confirmed ->
            :already_confirmed

          row.state == :manual_required and is_nil(row.token_ciphertext) and
            Enum.all?(@owner_keys, &is_nil(Map.get(row, &1))) and
            binding.state == :revocation_required and is_nil(binding.token_ciphertext) ->
            Refreshes.confirmed_project_removed!(scope, inbox_id)
            Grants.confirm_all_removed!(scope, inbox_id)

            scope.repo.update!(
              Ecto.Changeset.change(row,
                state: :complete,
                outcome: :operator_confirmed,
                next_attempt_at: nil
              ),
              prefix: scope.prefix,
              log: false
            )

            scope.repo.update!(Ecto.Changeset.change(binding, state: :disconnected),
              prefix: scope.prefix,
              log: false
            )

            :operator_confirmed

          true ->
            scope.repo.rollback(:manual_confirmation_unavailable)
        end
      end)
    else
      _ -> {:error, :invalid_confirmation}
    end
  rescue
    _ -> {:error, :manual_confirmation_unavailable}
  catch
    _, _ -> {:error, :manual_confirmation_unavailable}
  end

  def confirm_manual(_, _, _, _), do: {:error, :invalid_confirmation}

  def tasks(config) do
    %{
      "google_revocations" => %{
        run: fn _ ->
          case tick(config.google_oauth) do
            {:ok, :idle} -> {:next, nil, 60_000}
            {:ok, _} -> {:next, nil, 0}
            _ -> :failed
          end
        end,
        timeout_ms: 70_000,
        queue: :revocations
      }
    }
  end

  def tick(config, options \\ []) do
    Owner.run(
      fn ->
        case Refreshes.quarantine_one() do
          :quarantined -> {:ok, :refresh_quarantined}
          :unavailable -> {:error, :revocation_unavailable}
          :idle -> revoke_one(config, options)
        end
      end,
      60_000
    )
  rescue
    _ -> {:error, :revocation_unavailable}
  catch
    _, _ -> {:error, :revocation_unavailable}
  end

  defp revoke_one(config, options) do
    case claim(Keyword.get(options, :now, DateTime.utc_now())) do
      {:ok, :idle} ->
        {:ok, :idle}

      {:ok, row} ->
        revoke = Keyword.get(options, :revoke, &OAuth.revoke/2)

        result =
          with {:ok, token} <-
                 SelfHost.open("gmail-token", row.inbox_id, row.token_ciphertext),
               do: revoke.(config, token)

        finish(row, result)

      _ ->
        {:error, :revocation_unavailable}
    end
  end

  defp claim(now) do
    scope = SelfHost.scope()

    ids =
      scope.repo.all(
        from(r in Revocation,
          where:
            r.state in [:pending, :processing] and
              (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now),
          order_by: [asc: r.updated_at, asc: r.inbox_id],
          limit: 100,
          select: r.inbox_id
        ),
        prefix: scope.prefix,
        log: false
      )

    Enum.reduce_while(ids, {:ok, :idle}, fn id, _ ->
      case claim_one(id, now) do
        {:ok, %Revocation{} = row} -> {:halt, {:ok, row}}
        {:ok, :idle} -> {:cont, {:ok, :idle}}
        _ -> {:halt, {:error, :revocation_unavailable}}
      end
    end)
  end

  defp claim_one(id, now) do
    result =
      Store.transaction(fn scoped ->
        Store.lock_mailbox(scoped, id)
        row = scoped.repo.get!(Revocation, id, prefix: scoped.prefix, log: false)
        due? = is_nil(row.next_attempt_at) or DateTime.compare(row.next_attempt_at, now) != :gt

        cond do
          not Refreshes.ready?(scoped, id) ->
            :idle

          row.state == :pending and due? ->
            take_claim(scoped, retain_current!(scoped, row))

          row.state == :processing and due? and Owner.proof(row) == :dead ->
            {:quarantine, row.request_id, row.owner_token}

          true ->
            :idle
        end
      end)

    case result do
      {:ok, {:quarantine, request, token}} ->
        # A wall-clock jump can make a persisted due timestamp look old. Only a
        # physical wait AFTER proving the old BEAM owner dead bounds its final
        # possible 13-second external helper. Never hold database locks here.
        Process.sleep(20_000)

        Store.transaction(fn scoped ->
          Store.lock_mailbox(scoped, id)
          current = scoped.repo.get!(Revocation, id, prefix: scoped.prefix, log: false)

          if current.state == :processing and current.request_id == request and
               current.owner_token == token and Owner.proof(current) == :dead,
             do: take_claim(scoped, retain_current!(scoped, current)),
             else: :idle
        end)

      other ->
        other
    end
  end

  defp take_claim(scope, row) do
    scope.repo.update!(
      Ecto.Changeset.change(
        row,
        Map.merge(Owner.capture(), %{
          state: :processing,
          next_attempt_at: DateTime.add(DateTime.utc_now(), 120)
        })
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  defp finish(row, result) do
    case Store.transaction(fn scope ->
           Store.lock_mailbox(scope, row.inbox_id)
           current = scope.repo.get!(Revocation, row.inbox_id, prefix: scope.prefix, log: false)

           if current.request_id != row.request_id or current.owner_token != row.owner_token or
                not Owner.owns?(current),
              do: scope.repo.rollback(:revocation_changed)

           binding = scope.repo.get(Binding, row.inbox_id, prefix: scope.prefix, log: false)

           if binding &&
                (binding.google_subject != row.google_subject or
                   binding.state not in [:revoking, :revocation_required]),
              do: scope.repo.rollback(:revocation_changed)

           {fields, state, outcome} =
             case result do
               :ok ->
                 {%{
                    state: :complete,
                    outcome: :revoked,
                    token_ciphertext: nil,
                    next_attempt_at: nil
                  }, :disconnected, :revoked}

               {:error, :refresh_token_invalid} ->
                 {%{
                    state: :complete,
                    outcome: :refresh_token_invalid,
                    token_ciphertext: nil,
                    next_attempt_at: nil
                  }, :disconnected, :credential_unusable}

               _ ->
                 attempts = current.attempts + 1
                 delay = min(30 * Integer.pow(2, min(attempts - 1, 7)), 3600)

                 {%{
                    state: :pending,
                    outcome: :unavailable,
                    attempts: attempts,
                    next_attempt_at: DateTime.add(DateTime.utc_now(), delay)
                  }, :revoking, :retry_scheduled}
             end

           {fields, state, outcome} =
             if result in [:ok, {:error, :refresh_token_invalid}] do
               if result == :ok, do: Refreshes.confirmed_project_removed!(scope, row.inbox_id)

               Grants.forget!(
                 scope,
                 row.inbox_id,
                 current.grant_fingerprint,
                 current.token_ciphertext
               )

               case Grants.next(scope, row.inbox_id) do
                 nil ->
                   if Refreshes.uncertain?(scope, row.inbox_id) do
                     {%{
                        state: :manual_required,
                        outcome: :missing_token,
                        token_ciphertext: nil,
                        grant_fingerprint: nil,
                        next_attempt_at: nil
                      }, :revocation_required, :manual_confirmation_required}
                   else
                     {Map.put(fields, :grant_fingerprint, nil), state, outcome}
                   end

                 next ->
                   {%{
                      state: :pending,
                      outcome: :none,
                      token_ciphertext: next.token_ciphertext,
                      grant_fingerprint: next.fingerprint,
                      next_attempt_at: nil,
                      attempts: 0
                    }, :revoking, :retirement_continues}
               end
             else
               {fields, state, outcome}
             end

           scope.repo.update!(Ecto.Changeset.change(current, Map.merge(clear_owner(), fields)),
             prefix: scope.prefix,
             log: false
           )

           if binding do
             scope.repo.update!(Ecto.Changeset.change(binding, state: state),
               prefix: scope.prefix,
               log: false
             )
           end

           outcome
         end) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :revocation_unavailable}
    end
  end

  # Upgrade a legacy in-flight retirement without losing its encrypted capability.
  defp retain_current!(scope, row) do
    if is_binary(row.token_ciphertext) and is_nil(row.grant_fingerprint) do
      fingerprint = Grants.retain_cipher!(scope, row.inbox_id, row.token_ciphertext)

      scope.repo.update!(Ecto.Changeset.change(row, grant_fingerprint: fingerprint),
        prefix: scope.prefix,
        log: false
      )
    else
      row
    end
  end

  defp clear_owner, do: Map.new(@owner_keys, &{&1, nil})
end
