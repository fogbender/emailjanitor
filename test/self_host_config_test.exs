defmodule EmailJanitor.SelfHostConfigTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.{Content, SelfHost.Config}

  setup do
    path = Path.join(System.tmp_dir!(), "selfhost-config-" <> Ecto.UUID.generate())
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    key = Path.join(path, "key")
    secret = Path.join(path, "web-secret")

    for {file, bytes} <- [{key, String.duplicate("k", 32)}, {secret, String.duplicate("s", 64)}] do
      File.write!(file, bytes)
      File.chmod!(file, 0o600)
    end

    on_exit(fn -> File.rm_rf!(path) end)

    %{
      path: path,
      key: key,
      secret: secret,
      env: %{
        "JANITOR_OWNER_EMAIL" => "Owner@Example.com",
        "JANITOR_PUBLIC_URL" => "https://janitor.example.com/",
        "JANITOR_CREDENTIAL_KEY_FILE" => key,
        "JANITOR_SECRET_KEY_BASE_FILE" => secret
      }
    }
  end

  test "runtime settings normalize identity and redact stable secret files", ctx do
    assert {:ok, config} = Config.load(ctx.env)
    assert config.owner_email == "owner@example.com"
    assert config.public_url == "https://janitor.example.com"
    assert config.google_oauth == nil
    assert config.database[:socket_dir] == "/run/postgresql"
    assert Content.read(config.credential_key) == String.duplicate("k", 32)
    refute inspect(config) =~ String.duplicate("k", 32)
    refute inspect(config) =~ String.duplicate("s", 64)
  end

  test "invalid key sizes and insecure secret permissions fail with fixed metadata only", ctx do
    File.write!(ctx.key, String.duplicate("k", 31))
    assert {:error, :invalid_self_host_config} = Config.load(ctx.env)
    File.write!(ctx.key, String.duplicate("k", 32))
    File.chmod!(ctx.key, 0o644)
    assert {:error, :invalid_self_host_config} = Config.load(ctx.env)
    File.chmod!(ctx.key, 0o600)
    File.write!(ctx.secret, String.duplicate("s", 63))
    assert {:error, :invalid_self_host_config} = Config.load(ctx.env)
  end

  test "only the AWS reference provider and HTTPS or loopback callback origins are accepted",
       ctx do
    for url <- [
          "http://janitor.example.com",
          "https://janitor.example.com:0",
          "https://janitor.example.com:65536",
          "https://janitor.example.com:99999",
          "https://janitor.example.com:",
          "https://janitor.example.com:0443",
          "https://.",
          "https://a..b",
          "https://-a.example.com",
          "https://a-.example.com",
          "https://foo_bar.example.com",
          "https://999.1.1.1",
          "https://1",
          "https://127.1",
          "https://1.2.3",
          "https://4294967295",
          "https://0x7f.1",
          "https://0177.1",
          "https://017.0.0.1",
          "https://1.2.3.04",
          "https://foo.123",
          "https://foo.0x10",
          "https://" <> String.duplicate("a", 64) <> ".example.com",
          "https://user@janitor.example.com",
          "https://janitor.example.com/path",
          "https://janitor.example.com?token=secret",
          "https://janitor.example.com#fragment",
          "https://example.com\r\nmalicious"
        ] do
      assert {:error, :invalid_self_host_config} =
               Config.load(Map.put(ctx.env, "JANITOR_PUBLIC_URL", url))
    end

    assert {:ok, _} = Config.load(Map.put(ctx.env, "JANITOR_PUBLIC_URL", "http://127.0.0.1:4000"))

    assert {:error, :invalid_self_host_config} =
             Config.load(Map.put(ctx.env, "AWS_REGION", "us-west-2"))

    assert {:error, :invalid_self_host_config} =
             Config.load(Map.put(ctx.env, "JANITOR_MODEL_PROVIDER", "azure"))

    assert {:error, :invalid_self_host_config} =
             Config.load(
               Map.put(ctx.env, "JANITOR_DATABASE_NAME", "database; DROP DATABASE other")
             )
  end

  test "Google client configuration binds the exact callback and keeps its secret redacted",
       ctx do
    client = Path.join(ctx.path, "google.json")

    data = %{
      "web" => %{
        "client_id" => "synthetic-client",
        "client_secret" => "PRIVATE_GOOGLE_CLIENT_SECRET",
        "redirect_uris" => ["https://janitor.example.com/auth/google/callback"]
      }
    }

    File.write!(client, Jason.encode!(data))
    File.chmod!(client, 0o600)
    env = Map.put(ctx.env, "JANITOR_GOOGLE_CLIENT_JSON_FILE", client)
    assert {:ok, config} = Config.load(env)
    assert config.google_oauth.redirect_uri == "https://janitor.example.com/auth/google/callback"
    refute inspect(config.google_oauth) =~ "PRIVATE_GOOGLE_CLIENT_SECRET"

    File.write!(
      client,
      Jason.encode!(
        put_in(data, ["web", "redirect_uris"], ["https://other.example.com/auth/google/callback"])
      )
    )

    assert {:error, :invalid_self_host_config} = Config.load(env)
    File.write!(client, String.duplicate("x", 32_769))
    assert {:error, :invalid_self_host_config} = Config.load(env)
  end
end
