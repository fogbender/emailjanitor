defmodule EmailJanitor.Store.TargetMigration do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:actions) do
      add(:message_categories, :map, null: false, default: %{})
      add(:remaining_metadata_ids, {:array, :text})
    end

    alter table(:action_candidates) do
      add(:evaluated_message_ids, {:array, :text})
      add(:remaining_message_ids, {:array, :text})
    end

    create table(:review_fences, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:message_id, :text, primary_key: true)
      add(:reviewed_at, :utc_datetime_usec, null: false)
    end
  end
end

defmodule EmailJanitor.Store.ReviewFence do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "review_fences" do
    field(:inbox_id, :string, primary_key: true)
    field(:message_id, :string, primary_key: true)
    field(:reviewed_at, :utc_datetime_usec)
  end
end
