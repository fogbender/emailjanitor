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
  end
end
