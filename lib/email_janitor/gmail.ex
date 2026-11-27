defmodule EmailJanitor.Gmail do
  @moduledoc "Narrow Gmail execution boundary. Credentials stay in host-supplied adapter options."
  @callback thread(String.t(), String.t(), keyword()) ::
              {:ok, list(EmailJanitor.Message.t())} | {:error, term()}
  @callback contacted(String.t(), list(String.t()), keyword()) ::
              {:ok, MapSet.t()} | {:error, term()}
  @callback history_id(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback remove_inbox(String.t(), list(String.t()), keyword()) :: :ok | {:error, term()}
  @doc """
  Resolve credentials and account checks before admission. Return a closure with
  frozen credentials valid for at least the full 60-second execution window.
  The closure must perform only the exact-ID mutation, with transport timeouts
  strictly below the executor's 30-second watchdog. It must not resolve or refresh
  credentials, check a profile, or perform any other preparatory network I/O.
  """
  @callback prepare_remove_inbox(String.t(), list(String.t()), keyword()) ::
              {:ok, (-> :ok | {:error, term()})} | {:error, term()}
  @optional_callbacks prepare_remove_inbox: 3

  @doc "Resolve credentials/account checks before a durable dispatch; never persist the returned closure."
  def prepare(adapter, inbox_id, message_ids, options) do
    with {:module, ^adapter} <- Code.ensure_loaded(adapter) do
      result =
        if function_exported?(adapter, :prepare_remove_inbox, 3),
          do: adapter.prepare_remove_inbox(inbox_id, message_ids, options),
          else: {:ok, fn -> adapter.remove_inbox(inbox_id, message_ids, options) end}

      case result do
        {:ok, mutation} when is_function(mutation, 0) -> {:ok, mutation}
        _ -> {:error, :gmail_unavailable}
      end
    else
      _ -> {:error, :gmail_unavailable}
    end
  rescue
    _ -> {:error, :gmail_unavailable}
  catch
    _, _ -> {:error, :gmail_unavailable}
  end
end
