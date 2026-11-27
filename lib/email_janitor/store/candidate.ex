defmodule EmailJanitor.Store.Candidate do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "action_candidates" do
    field(:inbox_id, :string)
    field(:message_ids, {:array, :string})
    timestamps(type: :utc_datetime_usec)
  end
end
