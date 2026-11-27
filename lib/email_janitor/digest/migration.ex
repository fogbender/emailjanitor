defmodule EmailJanitor.Digest.Migration do
  @moduledoc "Activity metadata and frozen digest snapshots. No rendered email or raw body columns."
  use Ecto.Migration

  def change do
    create table(:digest_schedules, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:timezone, :text, null: false)
      add(:last_cutoff, :utc_datetime_usec, null: false)
      add(:delivery_date, :date)
      add(:delivery_digest_id, :uuid)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:digests, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:timezone, :text, null: false)
      add(:local_date, :date, null: false)
      add(:cutoff, :utc_datetime_usec, null: false)
      add(:outbox_id, references(:mail_outbox, type: :uuid), null: false)
      add(:first, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:digests, [:inbox_id, :cutoff]))
    create(unique_index(:digests, [:outbox_id]))

    create table(:digest_activity, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:source_id, :uuid, null: false)
      add(:message_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:sender, :text, null: false)
      add(:subject, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:digest_id, references(:digests, type: :uuid))
      add(:retired, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:digest_activity, [:inbox_id, :source_id, :message_id, :kind]))

    create(
      unique_index(:digest_activity, [:inbox_id, :message_id],
        where: "kind = 'would_have_done'",
        name: :once_hypothetical_digest_activity
      )
    )

    create(
      index(:digest_activity, [:inbox_id, :occurred_at],
        where: "digest_id IS NULL AND NOT retired",
        name: :unlisted_digest_activity
      )
    )

    create(index(:digest_activity, [:digest_id]))

    create(
      constraint(:digest_activity, :digest_kind, check: "kind IN ('done', 'would_have_done')")
    )
  end
end
