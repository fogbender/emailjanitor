defmodule EmailJanitor.Google.ServiceToken do
  @moduledoc """
  Read the root-owned federation helper's rotating, read-only runtime token file.

  Paths are static trusted host configuration, never request/model parameters.
  The helper owns workload credentials and metadata-server access; this reader
  only returns a redacted short-lived Pub/Sub access token. It never falls back
  to ambient Google accounts, credential stores or metadata endpoints.
  """
  import Bitwise
  alias EmailJanitor.Content
  @limit 32_768

  def read(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %{type: :regular, size: size, mode: mode}} <- File.lstat(path),
         true <- size <= @limit and band(mode, 0o027) == 0,
         {:ok, binary} <- bounded_read(path),
         {:ok, %{"access_token" => token, "expires_at" => expires_at} = value} <-
           Jason.decode(binary),
         true <- map_size(value) == 2,
         true <- is_integer(expires_at),
         now = System.system_time(:second),
         true <- expires_at >= now + 60 and expires_at <= now + 3660,
         true <-
           is_binary(token) and byte_size(token) in 16..16_384 and
             Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token) do
      {:ok, Content.new(token)}
    else
      _ -> {:error, :service_token_unavailable}
    end
  rescue
    _ -> {:error, :service_token_unavailable}
  catch
    _, _ -> {:error, :service_token_unavailable}
  end

  def read(_), do: {:error, :service_token_unavailable}

  defp bounded_read(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        case :file.read(file, @limit + 1) do
          {:ok, data} when byte_size(data) <= @limit -> {:ok, data}
          _ -> {:error, :invalid_runtime_file}
        end
      after
        :file.close(file)
      end
    end
  end
end
