defmodule EmailJanitor.Gmail.Ingestion.Migration do
  @moduledoc "Scoped metadata-only Gmail ingestion, migration version 10."
  use Ecto.Migration

  def change do
    create table(:gmail_ingestion, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:address, :text, null: false)
      add(:generation, :uuid, null: false)
      add(:generation_started_at, :utc_datetime_usec, null: false)
      add(:baseline_id, :text, null: false)
      add(:cursor, :text, null: false)
      add(:requested_id, :text)
      add(:watch_expires_at, :utc_datetime_usec, null: false)
      add(:status, :text, null: false, default: "active")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:gmail_ingestion, :valid_gmail_ingestion_status,
        check: "status IN ('active', 'gap')"
      )
    )

    create table(:gmail_arrivals, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:generation, :uuid, primary_key: true)
      add(:message_id, :text, primary_key: true)
      add(:observed_history_id, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:gmail_arrivals, [:inbox_id, :generation, :status]))

    create(
      constraint(:gmail_arrivals, :valid_gmail_arrival_status,
        check: "status IN ('pending', 'processed')"
      )
    )
  end
end

defmodule EmailJanitor.Gmail.Ingestion.Checkpoint do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:inbox_id, :string, autogenerate: false}
  schema "gmail_ingestion" do
    field(:address, :string)
    field(:generation, Ecto.UUID)
    field(:generation_started_at, :utc_datetime_usec)
    field(:baseline_id, :string)
    field(:cursor, :string)
    field(:requested_id, :string)
    field(:watch_expires_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:active, :gap], default: :active)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Gmail.Ingestion.Arrival do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "gmail_arrivals" do
    field(:inbox_id, :string, primary_key: true)
    field(:generation, Ecto.UUID, primary_key: true)
    field(:message_id, :string, primary_key: true)
    field(:observed_history_id, :string)
    field(:status, Ecto.Enum, values: [:pending, :processed], default: :pending)
    timestamps(type: :utc_datetime_usec)
  end
end
