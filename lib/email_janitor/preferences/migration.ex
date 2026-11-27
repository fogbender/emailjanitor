defmodule EmailJanitor.Preferences.Migration do
  use Ecto.Migration

  def change do
    create table(:preferences, primary_key: false) do
      add(:key, :text, primary_key: true)
      add(:instruction, :text, null: false)
      add(:revision, :bigint, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:preferences, :bounded_preferences,
        check: "octet_length(instruction) <= 15000 AND revision > 0"
      )
    )

    create table(:preference_changes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:target_key, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:changed, :boolean, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
