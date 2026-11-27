defmodule EmailJanitor.Mail.Credentials do
  @moduledoc "Explicit EC2 role or root-helper runtime-file resolvers; no ambient developer credentials."
  import Bitwise
  @limit 32_768

  @doc "Read the trusted helper's atomic, group-readable 15-minute STS credential file."
  def read(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %{type: :regular, size: size, mode: mode}} <- File.lstat(path),
         true <- size <= @limit and band(mode, 0o027) == 0,
         {:ok, binary} <- bounded_read(path),
         {:ok, value} <- Jason.decode(binary),
         %{
           "access_key_id" => key,
           "secret_access_key" => secret,
           "security_token" => token,
           "expires_at" => expiry
         } <- value,
         true <- map_size(value) == 4,
         now = System.system_time(:second),
         true <- is_integer(expiry) and expiry >= now + 60 and expiry <= now + 960,
         true <- is_binary(key) and Regex.match?(~r/\AASIA[A-Z0-9]{16}\z/, key),
         true <- is_binary(secret) and Regex.match?(~r/\A[A-Za-z0-9\/+]{40}\z/, secret),
         true <-
           is_binary(token) and byte_size(token) in 16..16_384 and
             Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token) do
      {:ok, [access_key_id: key, secret_access_key: secret, security_token: token]}
    else
      _ -> {:error, :mail_credentials_unavailable}
    end
  rescue
    _ -> {:error, :mail_credentials_unavailable}
  catch
    _, _ -> {:error, :mail_credentials_unavailable}
  end

  def read(_), do: {:error, :mail_credentials_unavailable}

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

  def instance_role(region) do
    config =
      ExAws.Config.new(:sts,
        region: region,
        access_key_id: :instance_role,
        secret_access_key: :instance_role,
        security_token: :instance_role,
        require_imds_v2: true
      )

    with key when is_binary(key) and key != "" <- config[:access_key_id],
         secret when is_binary(secret) and secret != "" <- config[:secret_access_key],
         token when is_binary(token) and token != "" <- config[:security_token] do
      {:ok, [access_key_id: key, secret_access_key: secret, security_token: token]}
    else
      _ -> {:error, :mail_credentials_unavailable}
    end
  rescue
    _ -> {:error, :mail_credentials_unavailable}
  catch
    _, _ -> {:error, :mail_credentials_unavailable}
  end
end
