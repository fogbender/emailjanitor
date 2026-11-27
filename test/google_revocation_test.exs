defmodule EmailJanitor.GoogleRevocationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Google.OAuth}

  setup do
    directory = Path.join(System.tmp_dir!(), "ej-revoke-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, config} = OAuth.Config.new("client", "secret", "http://127.0.0.1/auth/google/callback")
    %{directory: directory, config: config}
  end

  defp helper(ctx, script) do
    path = Path.join(ctx.directory, "helper")
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o700)
    path
  end

  test "the boundary sends only the refresh token through stdin and no credential arguments",
       ctx do
    helper =
      helper(ctx, ~S"""
      test "$#" -eq 0 || exit 1
      IFS= read -r frame
      test "$frame" = '{"refresh_token":"PRIVATE_REFRESH_SENTINEL"}' || exit 1
      printf '{"status":"revoked"}\n'
      """)

    token =
      Content.new(
        Jason.encode!(%{
          refresh_token: "PRIVATE_REFRESH_SENTINEL",
          access_token: "EXPIRED_ACCESS_SENTINEL",
          expires_at: 1
        })
      )

    assert :ok = OAuth.revoke(ctx.config, token, executable: helper)
    assert :ok = OAuth.revoke(%{ctx.config | revocation_executable: helper}, token)
  end

  test "access-only, invalid or missing configuration never starts the helper", ctx do
    helper = helper(ctx, "exit 90\n")

    for value <- [
          "{}",
          "not JSON",
          ~s({"access_token":"EXPIRED_ACCESS_SENTINEL"}),
          ~s({"refresh_token":"bad\\nvalue"})
        ] do
      assert {:error, :revocation_unavailable} =
               OAuth.revoke(ctx.config, Content.new(value), executable: helper)
    end

    assert {:error, :revocation_unavailable} = OAuth.revoke(ctx.config, Content.new("{}"), [])
  end

  test "provider-invalid tokens remain typed pending and arbitrary output never becomes successful erasure",
       ctx do
    token = Content.new(~s({"refresh_token":"PRIVATE_REFRESH_SENTINEL"}))

    invalid =
      helper(ctx, "IFS= read -r frame\nprintf '{\"status\":\"refresh_token_invalid\"}\\n'\n")

    assert {:error, :refresh_token_invalid} = OAuth.revoke(ctx.config, token, executable: invalid)

    for output <- [
          "PRIVATE_PROVIDER_BODY_SENTINEL",
          ~s({"status":"revoked","extra":true}),
          String.duplicate("X", 2048)
        ] do
      helper = helper(ctx, "IFS= read -r frame\nprintf '%s' '#{output}'\n")

      log =
        capture_log(fn ->
          assert {:error, :revocation_unavailable} =
                   OAuth.revoke(ctx.config, token, executable: helper)
        end)

      refute log =~ "PRIVATE_PROVIDER_BODY_SENTINEL"
      refute log =~ "PRIVATE_REFRESH_SENTINEL"
    end
  end
end
