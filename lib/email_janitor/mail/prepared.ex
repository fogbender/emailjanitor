defmodule EmailJanitor.Mail.Prepared do
  @moduledoc false
  @enforce_keys [:options]
  defstruct [:options]

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Mail.Prepared<[REDACTED]>"
  end

  defimpl Jason.Encoder do
    def encode(_, opts), do: Jason.Encode.string("[REDACTED]", opts)
  end
end
