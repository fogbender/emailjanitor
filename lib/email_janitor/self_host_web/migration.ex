defmodule EmailJanitor.SelfHostWeb.Migration do
  use Ecto.Migration

  def change do
    create table(:selfhost_web_sessions, primary_key: false) do
      add(:id, :binary, primary_key: true)
      add(:subject, :string, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(index(:selfhost_web_sessions, [:expires_at]))

    create table(:selfhost_web_attempts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:browser_hash, :binary, null: false)
      add(:client_hash, :binary, null: false)
      add(:session_hash, :binary)
      add(:subject, :string)
      add(:mode, :string, null: false)
      add(:timezone, :string, null: false)
      add(:ciphertext, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:selfhost_web_attempts, [:browser_hash]))
    create(index(:selfhost_web_attempts, [:expires_at]))
    create(index(:selfhost_web_attempts, [:client_hash, :expires_at]))
  end
end
