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
    field(:state, Ecto.Enum, values: [:pending, :processing, :manual_required, :complete])

    field(:outcome, Ecto.Enum,
      values: [
        :none,
        :unavailable,
        :refresh_token_invalid,
        :missing_token,
        :revoked,
        :credential_unusable
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
  alias EmailJanitor.SelfHost.{Binding, Revocation, Store}

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

  @doc "Called only under the scoped mailbox lock in the disconnect transaction."
  def stage!(scope, binding) do
    if not scope.repo.in_transaction?(),
      do: raise(ArgumentError, "retirement requires mailbox transaction")

    existing = scope.repo.get(Revocation, binding.id, prefix: scope.prefix, log: false)

    if existing && existing.state != :complete do
      if existing.google_subject != binding.google_subject,
        do: scope.repo.rollback(:connection_changed)

      if existing.state == :manual_required, do: :revocation_required, else: :revoking
    else
      present = is_binary(binding.token_ciphertext)
      unusable = not present and binding.state == :reauthorization_required

      fields = %{
        request_id: Ecto.UUID.generate(),
        google_subject: binding.google_subject,
        token_ciphertext: binding.token_ciphertext,
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

  def child_spec(config),
    do:
      Supervisor.child_spec(
        {EmailJanitor.Mail.Job,
         run: fn _ ->
           case tick(config.google_oauth) do
             {:ok, :idle} -> {:next, nil, 60_000}
             {:ok, _} -> {:next, nil, 0}
             _ -> {:next, nil, 60_000}
           end
         end,
         timeout_ms: 70_000},
        id: __MODULE__
      )

  def tick(config, options \\ []) do
    Owner.run(
      fn ->
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
      end,
      60_000
    )
  rescue
    _ -> {:error, :revocation_unavailable}
  catch
    _, _ -> {:error, :revocation_unavailable}
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
          row.state == :pending and due? ->
            take_claim(scoped, row)

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
             do: take_claim(scoped, current),
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

           binding = scope.repo.get!(Binding, row.inbox_id, prefix: scope.prefix, log: false)

           if binding.google_subject != row.google_subject or
                binding.state not in [:revoking, :revocation_required],
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

           scope.repo.update!(Ecto.Changeset.change(current, Map.merge(clear_owner(), fields)),
             prefix: scope.prefix,
             log: false
           )

           scope.repo.update!(Ecto.Changeset.change(binding, state: state),
             prefix: scope.prefix,
             log: false
           )

           outcome
         end) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :revocation_unavailable}
    end
  end

  defp clear_owner, do: Map.new(@owner_keys, &{&1, nil})
end
