defmodule EmailJanitor.SelfHost.Owner do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :integer, autogenerate: false}
  schema "self_host_owner" do
    field(:subject, :string)
    field(:email, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.SelfHost.Binding do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  @derive {Inspect, only: [:id, :state, :timezone, :epoch]}
  schema "self_host_bindings" do
    field(:google_subject, :string)
    field(:timezone, :string)

    field(:state, Ecto.Enum,
      values: [:pending, :active, :disconnected, :reauthorization_required]
    )

    field(:epoch, :integer, default: 1)
    field(:reset_baseline, :boolean, default: false)
    field(:token_version, :integer, default: 1)
    field(:token_ciphertext, :binary, redact: true)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.SelfHost.HistoricalAddress do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "self_host_addresses" do
    field(:inbox_id, :string, primary_key: true)
    field(:address, :string, primary_key: true)
  end
end
