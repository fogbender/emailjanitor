defmodule EmailJanitor.Mail.Migration do
  @moduledoc "Metadata only; full incoming/outgoing messages never enter PostgreSQL."
  use Ecto.Migration

  def change do
    create table(:mail_outbox, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:kind, :text, null: false)
      add(:reference_ids, {:array, :uuid}, null: false)
      add(:dedupe_id, :uuid, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:provider_id, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mail_outbox, [:inbox_id, :kind, :dedupe_id]))
    create(constraint(:mail_outbox, :mail_kind, check: "kind IN ('digest', 'assistant')"))

    create(
      constraint(:mail_outbox, :mail_state,
        check: "state IN ('pending', 'dispatching', 'sent', 'unresolved')"
      )
    )

    create table(:mail_spool, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:object_key, :text, null: false)
      add(:envelope_from, :text, null: false)
      add(:recipients, {:array, :text}, null: false)
      add(:verdicts, :map, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:state, :text, null: false, default: "pending")
      add(:claim_id, :uuid)
      add(:lease_until, :utc_datetime_usec)
      add(:workflow_id, :uuid)
      add(:outcome, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:mail_spool, [:expires_at, :state]))

    create(
      constraint(:mail_spool, :spool_state,
        check: "state IN ('pending', 'processing', 'purge', 'deleted')"
      )
    )

    create(
      constraint(:mail_spool, :spool_outcome,
        check: "outcome IS NULL OR outcome IN ('processed', 'ignored', 'rejected', 'expired')"
      )
    )
  end
end
