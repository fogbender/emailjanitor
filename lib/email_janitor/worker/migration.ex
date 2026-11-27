defmodule EmailJanitor.Worker.Migration do
  @moduledoc "Scoped metadata-only worker receipts/deferred work, migration 11."
  use Ecto.Migration

  def change do
    create table(:janitor_worker_receipts, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:action_id, references(:actions, type: :uuid), primary_key: true)
      add(:action_updated_at, :utc_datetime_usec, null: false)
      add(:status, :text, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:janitor_worker_receipts, :worker_receipt_status,
        check: "status IN ('retry', 'settled') AND attempts >= 0"
      )
    )

    create table(:janitor_worker_deferrals, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:generation, :uuid, primary_key: true)
      add(:thread_id, :text, primary_key: true)
      add(:fingerprint, :text, null: false)
      add(:instruction_version, :integer, null: false)
      add(:message_ids, {:array, :text}, null: false)
      add(:status, :text, null: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:janitor_worker_deferrals, :worker_deferral_status,
        check:
          "status IN ('unreadable', 'transient', 'blocked', 'invalid') AND attempts >= 0 AND instruction_version > 0"
      )
    )

    create(index(:janitor_worker_deferrals, [:inbox_id, :generation, :instruction_version]))

    create table(:janitor_worker_candidates, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:candidate_id, :uuid, primary_key: true)
      add(:generation, :uuid, null: false)
      add(:thread_id, :text, null: false)
      add(:message_ids, {:array, :text}, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:requested, :boolean, null: false, default: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:invalid_attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:janitor_worker_candidates, :worker_candidate_status,
        check: "status IN ('pending', 'retired') AND attempts >= 0 AND invalid_attempts >= 0"
      )
    )

    create table(:janitor_worker_watches, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:generation, :uuid, null: false)
      add(:renewed_at, :utc_datetime_usec, null: false)
    end
  end
end

defmodule EmailJanitor.Worker.Receipt do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "janitor_worker_receipts" do
    field(:inbox_id, :string, primary_key: true)
    field(:action_id, Ecto.UUID, primary_key: true)
    field(:action_updated_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:retry, :settled])
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Worker.Deferral do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "janitor_worker_deferrals" do
    field(:inbox_id, :string, primary_key: true)
    field(:generation, Ecto.UUID, primary_key: true)
    field(:thread_id, :string, primary_key: true)
    field(:fingerprint, :string)
    field(:instruction_version, :integer)
    field(:message_ids, {:array, :string})
    field(:status, Ecto.Enum, values: [:unreadable, :transient, :blocked, :invalid])
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Worker.Watch do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:inbox_id, :string, autogenerate: false}
  schema "janitor_worker_watches" do
    field(:generation, Ecto.UUID)
    field(:renewed_at, :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Worker.Candidate do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "janitor_worker_candidates" do
    field(:inbox_id, :string, primary_key: true)
    field(:candidate_id, Ecto.UUID, primary_key: true)
    field(:generation, Ecto.UUID)
    field(:thread_id, :string)
    field(:message_ids, {:array, :string})
    field(:status, Ecto.Enum, values: [:pending, :retired], default: :pending)
    field(:requested, :boolean, default: false)
    field(:attempts, :integer, default: 0)
    field(:invalid_attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
