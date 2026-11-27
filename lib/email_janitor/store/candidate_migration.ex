defmodule EmailJanitor.Store.CandidateMigration do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:action_candidates, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:thread_id, :text, null: false)
      add(:message_key, :binary, null: false)
      add(:message_ids, {:array, :text}, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:action_candidates, [:inbox_id, :message_key]))
  end
end
