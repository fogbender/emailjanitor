defmodule EmailJanitor.Inbox do
  @moduledoc "One connected inbox's non-secret identity and operator-supplied relay addresses."
  alias EmailJanitor.Address
  @enforce_keys [:id, :address]
  defstruct [:id, :address, relay_addresses: []]

  def new(id, address, relays \\ []) when is_binary(id) and is_list(relays) do
    with {:ok, address} <- Address.normalize(address),
         {:ok, normalized} <- normalize_relays(relays, address) do
      {:ok, %__MODULE__{id: id, address: address, relay_addresses: normalized}}
    end
  end

  defp normalize_relays(relays, address) do
    Enum.reduce_while(relays, {:ok, []}, fn relay, {:ok, acc} ->
      case Address.normalize(relay) do
        {:ok, normalized} ->
          if Address.within?(Address.domain(normalized), Address.domain(address)) do
            {:cont, {:ok, Enum.uniq([normalized | acc])}}
          else
            {:halt, {:error, :invalid_relay}}
          end

        _ ->
          {:halt, {:error, :invalid_relay}}
      end
    end)
  end
end
