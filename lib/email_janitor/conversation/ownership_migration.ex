defmodule EmailJanitor.Conversation.OwnershipMigration do
  use Ecto.Migration

  def change do
    alter table(:conversation_receipts) do
      add(:owner_token, :uuid)
      add(:owner_runtime, :text)
      add(:owner_host, :text)
      add(:owner_boot, :text)
      add(:owner_os_pid, :text)
      add(:owner_os_start, :text)
      add(:owner_beam_pid, :binary)
    end

    create table(:conversation_action_bindings, primary_key: false) do
      add(:action_id, :uuid, primary_key: true)

      add(:request_id, references(:conversation_receipts, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:inbox_id, :text, null: false)
      add(:message_ids, {:array, :text}, null: false)
    end

    create(index(:conversation_action_bindings, [:request_id, :inbox_id]))
  end
end
