defmodule EmailJanitor.GoogleServiceTokenTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Google.ServiceToken}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "ej-service-token-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, path: Path.join(directory, "token.json")}
  end

  defp write(path, changes \\ %{}) do
    value =
      Map.merge(
        %{
          "access_token" => "SERVICE_TOKEN_SENTINEL",
          "expires_at" => System.system_time(:second) + 3600
        },
        changes
      )

    File.write!(path, Jason.encode!(value))
    File.chmod!(path, 0o640)
  end

  test "reads only a private, fresh, exact-format token into redacted Content", %{path: path} do
    write(path)
    assert {:ok, %Content{} = token} = ServiceToken.read(path)
    assert Content.read(token) == "SERVICE_TOKEN_SENTINEL"
    refute inspect(token) =~ "SERVICE_TOKEN_SENTINEL"
    refute Jason.encode!(token) =~ "SERVICE_TOKEN_SENTINEL"
    write(path, %{"access_token" => "ROTATED_TOKEN_SENTINEL"})
    assert {:ok, token} = ServiceToken.read(path)
    assert Content.read(token) == "ROTATED_TOKEN_SENTINEL"
  end

  test "refuses stale, expiring, malformed and overprivileged token records", %{path: path} do
    for changes <- [
          %{"expires_at" => 1},
          %{"expires_at" => System.system_time(:second) + 10},
          %{"expires_at" => System.system_time(:second) + 7200},
          %{"expires_at" => "not-an-integer"},
          %{"access_token" => "secret\r\nheader"},
          %{"refresh_token" => "FORBIDDEN"}
        ] do
      write(path, changes)
      assert {:error, :service_token_unavailable} = ServiceToken.read(path)
    end
  end

  test "rejects missing, public/writable, symbolic, large and non-file paths", %{
    path: path,
    directory: directory
  } do
    assert {:error, :service_token_unavailable} = ServiceToken.read(path)
    write(path)

    for mode <- [0o644, 0o660, 0o666] do
      File.chmod!(path, mode)
      assert {:error, :service_token_unavailable} = ServiceToken.read(path)
    end

    File.chmod!(path, 0o640)
    alias_path = Path.join(directory, "alias.json")
    File.ln_s!(path, alias_path)
    assert {:error, :service_token_unavailable} = ServiceToken.read(alias_path)
    assert {:error, :service_token_unavailable} = ServiceToken.read(directory)
    assert {:error, :service_token_unavailable} = ServiceToken.read("relative.json")
    File.write!(path, String.duplicate("x", 32_769))
    assert {:error, :service_token_unavailable} = ServiceToken.read(path)
  end

  test "runtime failures produce no credential logs", %{path: path} do
    write(path, %{"access_token" => "SECRET\nINVALID"})

    assert capture_log(fn ->
             assert {:error, :service_token_unavailable} = ServiceToken.read(path)
           end) == ""
  end
end
