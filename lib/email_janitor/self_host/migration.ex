defmodule EmailJanitor.SelfHost.Migration do
  @moduledoc false
  use Ecto.Migration

  def change do
    # Recreated accounts can reuse an address but need a new subject-bound ID.
    # Keep historical inbox rows instead of reassigning their identity.
    drop(unique_index(:inboxes, [:address]))
    create(index(:inboxes, [:address]))

    create table(:self_host_owner, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:subject, :text, null: false)
      add(:email, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:self_host_owner, :single_owner, check: "id = 1"))

    create table(:self_host_bindings, primary_key: false) do
      add(:id, references(:inboxes, type: :text), primary_key: true)
      add(:google_subject, :text, null: false)
      add(:timezone, :text, null: false)
      add(:state, :text, null: false)
      add(:epoch, :bigint, null: false, default: 1)
      add(:reset_baseline, :boolean, null: false, default: false)
      add(:token_version, :bigint, null: false, default: 1)
      add(:token_ciphertext, :binary)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:self_host_addresses, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:address, :text, primary_key: true)
    end

    create(
      constraint(:self_host_bindings, :binding_state,
        check: "state IN ('pending', 'active', 'disconnected', 'reauthorization_required')"
      )
    )
  end
end
