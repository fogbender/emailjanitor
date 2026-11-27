defmodule EmailJanitor.Content do
  @moduledoc """
  Transient email content. Inspection and JSON serialization always redact it.

  This prevents accidental ordinary logging, not all possible leaks: consumers
  must not persist `read/1` or interpolate provider/parser exceptions. Boundaries
  return fixed error categories instead of raw exception messages.
  """
  @enforce_keys [:value]
  defstruct [:value]
  @opaque t :: %__MODULE__{value: binary()}

  def new(value) when is_binary(value), do: %__MODULE__{value: value}
  def read(%__MODULE__{value: value}), do: value

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Content<[REDACTED]>"
  end

  defimpl Jason.Encoder do
    def encode(_, opts), do: Jason.Encode.string("[REDACTED]", opts)
  end
end
