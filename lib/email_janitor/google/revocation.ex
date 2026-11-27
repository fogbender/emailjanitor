defmodule EmailJanitor.Google.Revocation do
  @moduledoc """
  Bounded official-SDK revocation of a stored Google refresh token.

  The trusted host supplies the pinned executable and retains its encrypted
  credential until positive confirmation. `:refresh_token_invalid` establishes
  only that this saved credential is unusable; it does not claim project-wide
  revocation. A host may retire that capability after permanently stopping all
  old attempts, with truthful local-access wording. Hosts block
  new grants for the same Google subject/project while revocation is pending.
  """
  alias EmailJanitor.Content

  def revoke(%Content{} = content, executable) when is_binary(executable) do
    with :ok <- EmailJanitor.TransportPrivacy.check(),
         true <- Path.type(executable) == :absolute,
         {:ok, %{type: :regular, mode: mode}} <- File.stat(executable),
         true <- Bitwise.band(mode, 0o111) != 0,
         raw <- Content.read(content),
         true <- byte_size(raw) <= 65_536,
         {:ok, %{"refresh_token" => token}} <- Jason.decode(raw),
         true <- is_binary(token) and Regex.match?(~r/\A[!-~]{1,32768}\z/, token) do
      frame = Jason.encode!(%{refresh_token: token}) <> "\n"

      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide
        ])

      try do
        true = Port.command(port, frame)
        receive_output(port, "", System.monotonic_time(:millisecond) + 15_000)
      after
        if Port.info(port), do: Port.close(port)
        drain(port)
      end
    else
      _ -> {:error, :revocation_unavailable}
    end
  rescue
    _ -> {:error, :revocation_unavailable}
  catch
    _, _ -> {:error, :revocation_unavailable}
  end

  def revoke(_, _), do: {:error, :revocation_unavailable}

  defp receive_output(port, buffer, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(buffer) + byte_size(data) <= 1024 ->
        receive_output(port, buffer <> data, deadline)

      {^port, {:exit_status, 0}} ->
        case buffer do
          "{\"status\":\"revoked\"}\n" -> :ok
          "{\"status\":\"refresh_token_invalid\"}\n" -> {:error, :refresh_token_invalid}
          _ -> {:error, :revocation_unavailable}
        end

      {^port, _} ->
        {:error, :revocation_unavailable}
    after
      timeout -> {:error, :revocation_unavailable}
    end
  end

  defp drain(port) do
    receive do
      {^port, _} -> drain(port)
    after
      0 -> :ok
    end
  end
end
