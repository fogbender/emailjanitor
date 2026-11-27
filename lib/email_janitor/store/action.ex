defmodule EmailJanitor.Store.Action do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "actions" do
    field(:inbox_id, :string)
    field(:thread_id, :string)
    field(:message_ids, {:array, :string})
    field(:applied_message_ids, {:array, :string}, default: [])
    field(:restored_message_ids, {:array, :string}, default: [])
    field(:fingerprint, :string)
    field(:history_id, :string)
    field(:instruction_version, :integer)
    field(:owner_token, Ecto.UUID)
    field(:owner_runtime, :string)
    field(:owner_host, :string)
    field(:owner_boot, :string)
    field(:owner_os_pid, :string)
    field(:owner_os_start, :string)
    field(:owner_beam_pid, :binary)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:dispatch_started_at, :utc_datetime_usec)
    field(:recovered_at, :utc_datetime_usec)

    field(:category, Ecto.Enum,
      values: [:cold_outreach, :legitimate, :uncertain, :user_instruction]
    )

    field(:state, Ecto.Enum, values: [:intent, :done, :restored, :cancelled, :unresolved])
    timestamps(type: :utc_datetime_usec)
  end
end
