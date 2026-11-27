defmodule EmailJanitor.Conversation.Receipt do
  @moduledoc "Metadata-only conversation effect receipt; no request, response, query or instruction text."
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "conversation_receipts" do
    field(:conversation_id, Ecto.UUID)
    field(:inbox_id, :string)
    field(:operation, Ecto.Enum, values: [:answer, :done, :restore])
    field(:preference_target, Ecto.Enum, values: [:none, :inbox, :all])
    field(:references, {:array, :map}, default: [])
    field(:context_references, {:array, :map}, default: [])
    field(:search_complete, :boolean, default: false)

    field(:preference_status, Ecto.Enum,
      values: [:none, :pending, :updated, :unchanged, :failed],
      default: :none
    )

    field(:preference_revision, :integer)
    field(:results, {:array, :map}, default: [])
    field(:completed, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end
end
