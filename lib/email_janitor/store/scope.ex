defmodule EmailJanitor.Store.Scope do
  @moduledoc "Explicit repository/schema boundary supplied by the embedding host, never by the model."
  @enforce_keys [:repo, :prefix]
  defstruct [:repo, :prefix]

  def new(repo, prefix) when is_atom(repo) and is_binary(prefix) do
    if Regex.match?(~r/\Aej_[a-z0-9_]{1,50}\z/, prefix) do
      {:ok, %__MODULE__{repo: repo, prefix: prefix}}
    else
      {:error, :invalid_storage_scope}
    end
  end
end
