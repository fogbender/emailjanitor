defmodule EmailJanitor.Restore.Migration do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:restore_effects, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:inbox_id, references(:inboxes, type: :text), null: false)
      add(:action_id, references(:actions, type: :uuid), null: false)
      add(:message_ids, {:array, :text}, null: false)
      add(:instruction_version, :integer, null: false)
      add(:state, :text, null: false)
      add(:owner_token, :uuid, null: false)
      add(:owner_runtime, :text, null: false)
      add(:owner_host, :text)
      add(:owner_boot, :text)
      add(:owner_os_pid, :text, null: false)
      add(:owner_os_start, :text)
      add(:owner_beam_pid, :binary, null: false)
      add(:lease_expires_at, :utc_datetime_usec, null: false)
      add(:dispatch_started_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:restore_effects, [:inbox_id, :state]))

    create(
      constraint(:restore_effects, :valid_restore_state,
        check:
          "state IN ('intent', 'done', 'cancelled', 'unresolved') AND cardinality(message_ids) BETWEEN 1 AND 5 AND instruction_version > 0"
      )
    )

    create table(:manual_restore_protections, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:message_id, :text, primary_key: true)
      add(:effect_id, references(:restore_effects, type: :uuid), null: false)
    end
  end
end

defmodule EmailJanitor.Restore.Effect do
  @moduledoc false
  use Ecto.Schema
  @derive {Inspect, only: [:id, :inbox_id, :state]}
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "restore_effects" do
    field(:inbox_id, :string)
    field(:action_id, Ecto.UUID)
    field(:message_ids, {:array, :string})
    field(:instruction_version, :integer)
    field(:state, Ecto.Enum, values: [:intent, :done, :cancelled, :unresolved])
    field(:owner_token, Ecto.UUID)
    field(:owner_runtime, :string)
    field(:owner_host, :string)
    field(:owner_boot, :string)
    field(:owner_os_pid, :string)
    field(:owner_os_start, :string)
    field(:owner_beam_pid, :binary)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:dispatch_started_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Restore.Protection do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "manual_restore_protections" do
    field(:inbox_id, :string, primary_key: true)
    field(:message_id, :string, primary_key: true)
    field(:effect_id, Ecto.UUID)
  end
end
