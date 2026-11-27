defmodule EmailJanitor.Store.Migration do
  @moduledoc "Single-instance persistence. The host supplies its database schema prefix."
  use Ecto.Migration

  def change do
    create table(:inboxes, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:address, :text, null: false)
      add(:instruction_version, :integer, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:inboxes, [:address]))

    create table(:actions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:thread_id, :text, null: false)
      add(:message_ids, {:array, :text}, null: false)
      add(:applied_message_ids, {:array, :text}, null: false, default: [])
      add(:restored_message_ids, {:array, :text}, null: false, default: [])
      add(:fingerprint, :text, null: false)
      add(:history_id, :text, null: false)
      add(:instruction_version, :integer, null: false)
      add(:owner_token, :uuid, null: false)
      add(:owner_runtime, :text, null: false)
      add(:owner_host, :text)
      add(:owner_boot, :text)
      add(:owner_os_pid, :text, null: false)
      add(:owner_os_start, :text)
      add(:owner_beam_pid, :binary, null: false)
      add(:lease_expires_at, :utc_datetime_usec, null: false)
      add(:dispatch_started_at, :utc_datetime_usec)
      add(:recovered_at, :utc_datetime_usec)
      add(:category, :text, null: false)
      add(:state, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:actions, [:inbox_id, :state]))

    create(
      constraint(:actions, :valid_action_state,
        check: "state IN ('intent', 'done', 'restored', 'cancelled', 'unresolved')"
      )
    )
  end
end
