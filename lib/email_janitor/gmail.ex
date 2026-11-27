defmodule EmailJanitor.Gmail do
  @moduledoc "Narrow Gmail execution boundary. Credentials stay in host-supplied adapter options."
  @callback thread(String.t(), String.t(), keyword()) ::
              {:ok, list(EmailJanitor.Message.t())} | {:error, term()}
  @callback contacted(String.t(), list(String.t()), keyword()) ::
              {:ok, MapSet.t()} | {:error, term()}
  @callback history_id(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback remove_inbox(String.t(), list(String.t()), keyword()) :: :ok | {:error, term()}
end
