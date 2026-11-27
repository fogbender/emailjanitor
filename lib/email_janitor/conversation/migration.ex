defmodule EmailJanitor.Conversation.Migration do
  use Ecto.Migration

  def change do
    create table(:conversation_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:conversation_id, :uuid, null: false)
      add(:inbox_id, references(:inboxes, type: :text, on_delete: :delete_all), null: false)
      add(:operation, :text, null: false)
      add(:preference_target, :text, null: false)
      add(:references, {:array, :map}, null: false, default: [])
      add(:context_references, {:array, :map}, null: false, default: [])
      add(:search_complete, :boolean, null: false, default: false)
      add(:preference_status, :text, null: false, default: "none")
      add(:preference_revision, :bigint)
      add(:results, {:array, :map}, null: false, default: [])
      add(:completed, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:conversation_receipts, [:inbox_id, :conversation_id, :inserted_at]))
    create(index(:conversation_receipts, [:inserted_at]))
  end
end
