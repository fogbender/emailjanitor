defmodule EmailJanitor.SelfHost.GoogleGrantMigration do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:self_host_google_grants, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:fingerprint, :binary, primary_key: true)
      add(:token_ciphertext, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:self_host_google_grants, :grant_fingerprint_size,
        check: "octet_length(fingerprint) = 32"
      )
    )

    create table(:self_host_refreshes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:source_version, :bigint, null: false)
      add(:state, :text, null: false)
      add(:owner_token, :uuid, null: false)
      add(:owner_runtime, :text)
      add(:owner_host, :text)
      add(:owner_boot, :text)
      add(:owner_os_pid, :text)
      add(:owner_os_start, :text)
      add(:owner_beam_pid, :binary)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:self_host_refreshes, [:inbox_id, :state]))

    create(
      constraint(:self_host_refreshes, :refresh_state,
        check: "state IN ('wire', 'ambiguous', 'quarantined')"
      )
    )

    alter table(:self_host_revocations) do
      add(:grant_fingerprint, :binary)
    end
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{prefix()}.self_host_google_grants) OR EXISTS (SELECT 1 FROM #{prefix()}.self_host_refreshes) THEN RAISE EXCEPTION 'Retained Google grants prevent rollback'; END IF; END $$"
    )

    alter(table(:self_host_revocations), do: remove(:grant_fingerprint))
    drop(table(:self_host_refreshes))
    drop(table(:self_host_google_grants))
  end
end

defmodule EmailJanitor.SelfHost.GoogleGrant do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  @derive {Inspect, only: [:inbox_id]}
  schema "self_host_google_grants" do
    field(:inbox_id, :string, primary_key: true)
    field(:fingerprint, :binary, primary_key: true, redact: true)
    field(:token_ciphertext, :binary, redact: true)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.SelfHost.Grants do
  @moduledoc "Encrypted offline capabilities retained until explicit, serialized retirement."
  import Ecto.Query
  alias EmailJanitor.{Content, SelfHost}
  alias EmailJanitor.SelfHost.{GoogleGrant, Store}

  def install(%EmailJanitor.Store.Scope{repo: SelfHost.Repo, prefix: "ej_selfhost"} = scope),
    do:
      Ecto.Migrator.up(scope.repo, 105, SelfHost.GoogleGrantMigration,
        prefix: scope.prefix,
        log: false
      )

  def install(_), do: {:error, :invalid_self_host_scope}

  @doc false
  def retain_cipher!(_scope, _inbox, nil), do: nil

  def retain_cipher!(scope, inbox, cipher) when is_binary(cipher) do
    case SelfHost.open("gmail-token", inbox, cipher) do
      {:ok, token} -> retain!(scope, inbox, token, cipher, replace: false)
      _ -> scope.repo.rollback(:credential_retention_unavailable)
    end
  end

  @doc false
  def retain!(scope, inbox, %Content{} = token, cipher, options \\ []) when is_binary(cipher) do
    transaction!(scope)

    case SelfHost.open("gmail-token", inbox, cipher) do
      {:ok, sealed} ->
        if Content.read(sealed) != Content.read(token),
          do: scope.repo.rollback(:credential_retention_unavailable)

      _ ->
        scope.repo.rollback(:credential_retention_unavailable)
    end

    fingerprint = fingerprint!(scope, inbox, token)
    now = DateTime.utc_now()

    scope.repo.insert_all(
      GoogleGrant,
      [
        %{
          inbox_id: inbox,
          fingerprint: fingerprint,
          token_ciphertext: cipher,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: scope.prefix,
      log: false,
      conflict_target: [:inbox_id, :fingerprint],
      on_conflict:
        if(Keyword.get(options, :replace, true),
          do: {:replace, [:token_ciphertext, :updated_at]},
          else: :nothing
        )
    )

    fingerprint
  end

  @doc false
  def next(scope, inbox) do
    scope.repo.one(
      from(g in GoogleGrant,
        where: g.inbox_id == ^inbox,
        order_by: [asc: g.inserted_at, asc: g.fingerprint],
        limit: 1
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  @doc false
  def forget!(scope, inbox, fingerprint, cipher) when is_binary(fingerprint) do
    transaction!(scope)

    scope.repo.delete_all(
      from(g in GoogleGrant,
        where:
          g.inbox_id == ^inbox and g.fingerprint == ^fingerprint and g.token_ciphertext == ^cipher
      ),
      prefix: scope.prefix,
      log: false
    )

    :ok
  end

  @doc false
  def forget_cipher!(scope, inbox, cipher) do
    with {:ok, token} <- SelfHost.open("gmail-token", inbox, cipher) do
      forget!(scope, inbox, fingerprint!(scope, inbox, token), cipher)
    else
      _ -> scope.repo.rollback(:credential_retention_unavailable)
    end
  end

  @doc false
  # Only the existing explicit local attestation may retire unknown capabilities.
  def confirm_all_removed!(scope, inbox) do
    transaction!(scope)

    scope.repo.delete_all(from(g in GoogleGrant, where: g.inbox_id == ^inbox),
      prefix: scope.prefix,
      log: false
    )

    :ok
  end

  defp fingerprint!(scope, inbox, content) do
    with {:ok, token} <- Store.token_data(content, require_mail_scope: false),
         %Content{} = key <- SelfHost.config().credential_key,
         bytes <- Content.read(key),
         true <- byte_size(bytes) == 32 do
      :crypto.mac(
        :hmac,
        :sha256,
        bytes,
        "emailjanitor/selfhost/google-grant/v1\0" <> inbox <> "\0" <> token["refresh_token"]
      )
    else
      _ -> scope.repo.rollback(:credential_retention_unavailable)
    end
  end

  defp transaction!(scope) do
    if not scope.repo.in_transaction?(),
      do: raise(ArgumentError, "grant retention requires mailbox transaction")
  end
end
