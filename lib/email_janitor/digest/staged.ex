defmodule EmailJanitor.Digest.Staged do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "digest_staged_activity" do
    field(:inbox_id, :string, primary_key: true)
    field(:action_id, Ecto.UUID, primary_key: true)
    field(:message_id, :string, primary_key: true)
    field(:sender, :string)
    field(:subject, :string)
    field(:occurred_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
