defmodule EmailJanitor.Worker.Migration do
  @moduledoc "Scoped metadata-only worker receipts/deferred work, migration 11."
  use Ecto.Migration

  def change do
    alter table(:gmail_arrivals) do
      add(:last_attempt_at, :utc_datetime_usec)
    end

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
          "status IN ('unreadable', 'transient', 'blocked', 'invalid', 'rejected') AND attempts >= 0 AND instruction_version > 0"
      )
    )

    create(index(:janitor_worker_deferrals, [:inbox_id, :generation, :instruction_version]))

    create table(:janitor_worker_candidates, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:candidate_id, :uuid, primary_key: true)
      add(:generation, :uuid, null: false)
      add(:thread_id, :text, null: false)
      add(:message_ids, {:array, :text}, null: false)
      add(:request_version, :bigint, null: false, default: 1)
      add(:source_kind, :text, null: false, default: "arrival")
      add(:authority_id, :uuid)
      add(:status, :text, null: false, default: "pending")
      add(:requested, :boolean, null: false, default: false)
      add(:contract_blocked, :boolean, null: false, default: false)
      add(:attempts, :integer, null: false, default: 0)
      add(:invalid_attempts, :integer, null: false, default: 0)
      add(:rejected_attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:janitor_worker_candidates, :worker_candidate_status,
        check:
          "status IN ('pending', 'retired') AND request_version > 0 AND attempts >= 0 AND invalid_attempts >= 0 AND rejected_attempts >= 0 AND ((source_kind = 'arrival' AND authority_id IS NULL) OR (source_kind = 'manual' AND authority_id IS NOT NULL))"
      )
    )

    create table(:janitor_worker_model_streaks, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:instruction_version, :integer, null: false)
      add(:bad_threads, {:array, :text}, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:janitor_worker_model_streaks, :worker_model_streak_bound,
        check: "instruction_version > 0 AND cardinality(bad_threads) BETWEEN 1 AND 4"
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
    field(:status, Ecto.Enum, values: [:unreadable, :transient, :blocked, :invalid, :rejected])
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
    field(:request_version, :integer, default: 1)
    field(:source_kind, Ecto.Enum, values: [:arrival, :manual], default: :arrival)
    field(:authority_id, Ecto.UUID)
    field(:message_ids, {:array, :string})
    field(:status, Ecto.Enum, values: [:pending, :retired], default: :pending)
    field(:requested, :boolean, default: false)
    field(:contract_blocked, :boolean, default: false)
    field(:attempts, :integer, default: 0)
    field(:invalid_attempts, :integer, default: 0)
    field(:rejected_attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Worker.Arrival do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "gmail_arrivals" do
    field(:inbox_id, :string, primary_key: true)
    field(:generation, Ecto.UUID, primary_key: true)
    field(:message_id, :string, primary_key: true)
    field(:observed_history_id, :string)
    field(:status, Ecto.Enum, values: [:pending, :processed])
    field(:last_attempt_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Worker.ModelStreak do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:inbox_id, :string, autogenerate: false}
  schema "janitor_worker_model_streaks" do
    field(:instruction_version, :integer)
    field(:bad_threads, {:array, :string})
    timestamps(type: :utc_datetime_usec)
  end
end
