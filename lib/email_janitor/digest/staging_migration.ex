defmodule EmailJanitor.Digest.StagingMigration do
  @moduledoc "Minimal action headers staged before Gmail, without an immediate actions FK."
  use Ecto.Migration

  def change do
    create table(:digest_staged_activity, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:action_id, :uuid, primary_key: true)
      add(:message_id, :text, primary_key: true)
      add(:sender, :text, null: false)
      add(:subject, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
