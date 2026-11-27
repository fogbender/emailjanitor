defmodule EmailJanitor.Mail.Store do
  @moduledoc "Install the metadata-only mail migration after the core schema."
  alias EmailJanitor.Store.Scope

  def install(%Scope{} = scope) do
    Ecto.Migrator.up(scope.repo, 4, EmailJanitor.Mail.Migration, prefix: scope.prefix, log: false)
  end
end

defmodule EmailJanitor.Mail.Outgoing do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "mail_outbox" do
    field(:inbox_id, :string)
    field(:kind, Ecto.Enum, values: [:digest, :assistant])
    field(:reference_ids, {:array, Ecto.UUID})
    field(:dedupe_id, Ecto.UUID)

    field(:state, Ecto.Enum,
      values: [:pending, :dispatching, :sent, :unresolved],
      default: :pending
    )

    field(:provider_id, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.Mail.Incoming do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "mail_spool" do
    field(:inbox_id, :string)
    field(:object_key, :string)
    field(:envelope_from, :string)
    field(:recipients, {:array, :string})
    field(:verdicts, :map)
    field(:expires_at, :utc_datetime_usec)
    field(:state, Ecto.Enum, values: [:pending, :processing, :purge, :deleted], default: :pending)
    field(:claim_id, Ecto.UUID)
    field(:lease_until, :utc_datetime_usec)
    field(:workflow_id, Ecto.UUID)
    field(:outcome, Ecto.Enum, values: [:processed, :ignored, :rejected, :expired, :too_large])
    timestamps(type: :utc_datetime_usec)
  end
end
