defmodule EmailJanitor.Digest.Schedule do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:inbox_id, :string, autogenerate: false}
  schema "digest_schedules" do
    field(:timezone, :string)
    field(:last_cutoff, :utc_datetime_usec)
    field(:delivery_date, :date)
    field(:delivery_digest_id, Ecto.UUID)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Digest.Snapshot do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "digests" do
    field(:inbox_id, :string)
    field(:timezone, :string)
    field(:local_date, :date)
    field(:cutoff, :utc_datetime_usec)
    field(:outbox_id, Ecto.UUID)
    field(:first, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Digest.Activity do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "digest_activity" do
    field(:inbox_id, :string)
    field(:source_id, Ecto.UUID)
    field(:message_id, :string)
    field(:kind, Ecto.Enum, values: [:done, :would_have_done])
    field(:sender, :string)
    field(:subject, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:digest_id, Ecto.UUID)
    field(:retired, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end
end
