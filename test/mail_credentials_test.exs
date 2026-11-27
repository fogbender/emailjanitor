defmodule EmailJanitor.MailCredentialsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias EmailJanitor.Mail.{Credentials, SDK}
  alias EmailJanitor.MailFixture, as: F

  setup do
    dir = Path.join(System.tmp_dir!(), "janitor-aws-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, credential_path: Path.join(dir, "credentials.json")}
  end

  defp value do
    %{
      "access_key_id" => "ASIA" <> String.duplicate("A", 16),
      "secret_access_key" => String.duplicate("x", 40),
      "security_token" => "SYNTHETIC_TOKEN_PRIVATE",
      "expires_at" => System.system_time(:second) + 900
    }
  end

  defp write(file, value) do
    File.write!(file, Jason.encode!(value))
    File.chmod!(file, 0o640)
  end

  test "reads a fresh complete credential set and rereads atomic rotation", ctx do
    write(ctx.credential_path, value())
    assert {:ok, credentials} = Credentials.read(ctx.credential_path)
    assert credentials[:access_key_id] == value()["access_key_id"]
    assert credentials[:security_token] == "SYNTHETIC_TOKEN_PRIVATE"
    replacement = Path.join(ctx.dir, "new.json")
    write(replacement, %{value() | "security_token" => "ROTATED_SYNTHETIC_TOKEN"})
    File.rename!(replacement, ctx.credential_path)
    assert {:ok, rotated} = Credentials.read(ctx.credential_path)
    assert rotated[:security_token] == "ROTATED_SYNTHETIC_TOKEN"
  end

  test "rejects stale, long-lived, ambient-key and malformed credentials without logs", ctx do
    log =
      capture_log(fn ->
        for invalid <- [
              %{value() | "expires_at" => System.system_time(:second) + 30},
              %{value() | "expires_at" => System.system_time(:second) + 3600},
              %{value() | "access_key_id" => "AKIA" <> String.duplicate("A", 16)},
              %{value() | "secret_access_key" => "PRIVATE_SENTINEL"},
              %{value() | "security_token" => "PRIVATE_SENTINEL\n"},
              Map.put(value(), "body", "PRIVATE_SENTINEL"),
              Map.delete(value(), "security_token"),
              %{value() | "expires_at" => "not an integer"},
              ["PRIVATE_SENTINEL"],
              nil
            ] do
          write(ctx.credential_path, invalid)
          assert {:error, :mail_credentials_unavailable} = Credentials.read(ctx.credential_path)
        end
      end)

    refute log =~ "PRIVATE_SENTINEL"
  end

  test "rejects insecure, symlinked, oversized, missing and non-file inputs", ctx do
    write(ctx.credential_path, value())

    for mode <- [0o644, 0o660] do
      File.chmod!(ctx.credential_path, mode)
      assert {:error, :mail_credentials_unavailable} = Credentials.read(ctx.credential_path)
    end

    File.chmod!(ctx.credential_path, 0o640)
    link = Path.join(ctx.dir, "link")
    File.ln_s!(ctx.credential_path, link)
    assert {:error, :mail_credentials_unavailable} = Credentials.read(link)
    File.write!(ctx.credential_path, String.duplicate("x", 32_769))
    assert {:error, :mail_credentials_unavailable} = Credentials.read(ctx.credential_path)

    for input <- [ctx.dir, Path.join(ctx.dir, "missing"), "relative.json", nil] do
      assert {:error, :mail_credentials_unavailable} = Credentials.read(input)
    end
  end

  test "maintained SDK signs with the fresh file credentials and refuses stale files", ctx do
    long_token = String.duplicate("x", 16_384)
    write(ctx.credential_path, %{value() | "security_token" => long_token})
    parent = self()

    base =
      F.config(fn conn ->
        send(
          parent,
          {:signed, Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "x-amz-security-token")}
        )

        Plug.Conn.send_resp(conn, 200, "")
      end)

    config = %{base | credentials: fn -> Credentials.read(ctx.credential_path) end}
    assert :ok = SDK.delete(config, "incoming/synthetic-receipt")
    assert_received {:signed, [authorization], [^long_token]}
    assert authorization =~ "Credential=" <> value()["access_key_id"] <> "/"

    write(ctx.credential_path, %{value() | "expires_at" => System.system_time(:second) - 1})
    assert {:error, :mail_unavailable} = SDK.delete(config, "incoming/synthetic-receipt")
    refute_received {:signed, _, _}
  end

  test "enforces the exact validity window", ctx do
    for seconds <- [59, 60, 960, 961] do
      result = stable_boundary(ctx.credential_path, seconds, 3)

      if seconds in [60, 960],
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, :mail_credentials_unavailable})
    end
  end

  defp stable_boundary(path, seconds, attempts) when attempts > 0 do
    now = System.system_time(:second)
    write(path, %{value() | "expires_at" => now + seconds})
    result = Credentials.read(path)

    if now == System.system_time(:second),
      do: result,
      else: stable_boundary(path, seconds, attempts - 1)
  end
end
