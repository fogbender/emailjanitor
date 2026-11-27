defmodule EmailJanitor.Store.Mailbox do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "inboxes" do
    field(:address, :string)
    field(:instruction_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
