defmodule EmailJanitor.SetupTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.{Content, Setup, SelfHost}
  alias EmailJanitor.Setup.CLI

  setup do
    parent = Path.join(System.tmp_dir!(), "janitor-setup-test-" <> Ecto.UUID.generate())
    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    on_exit(fn -> File.rm_rf!(parent) end)
    %{parent: parent, directory: Path.join(parent, "private")}
  end

  test "init shares runtime validation, creates private keys and cannot overwrite them", ctx do
    assert {:ok, %{callback: "https://janitor.example.com/auth/google/callback"}} =
             Setup.init(ctx.directory, "Owner@Example.com", "https://janitor.example.com/")

    assert {:ok, env} = Setup.load_settings(Path.join(ctx.directory, "settings.json"))
    assert env["JANITOR_ENABLE_SELF_HOST"] == "0"
    assert env["JANITOR_OWNER_EMAIL"] == "owner@example.com"
    assert {:ok, config} = SelfHost.Config.load(env)
    assert byte_size(Content.read(config.credential_key)) == 32
    assert byte_size(Content.read(config.web_secret)) >= 64

    refute File.read!(Path.join(ctx.directory, "settings.json")) =~
             Content.read(config.web_secret)

    assert Bitwise.band(File.stat!(ctx.directory).mode, 0o777) == 0o700

    for file <- ["credential-key", "web-secret", "settings.json"] do
      assert Bitwise.band(File.stat!(Path.join(ctx.directory, file)).mode, 0o777) == 0o600
    end

    before = File.read!(env["JANITOR_CREDENTIAL_KEY_FILE"])

    assert {:error, :setup_directory_exists} =
             Setup.init(ctx.directory, "other@example.com", "https://other.example.com")

    assert File.read!(env["JANITOR_CREDENTIAL_KEY_FILE"]) == before
    assert File.read!(Path.join(ctx.directory, ".gitignore")) =~ "*"
  end

  test "invalid setup leaves no partial key directory and rejects store paths", ctx do
    assert {:error, :invalid_setup_configuration} =
             Setup.init(ctx.directory, "owner@example.com", "http://public.example.com")

    refute File.exists?(ctx.directory)

    assert {:error, :invalid_setup_configuration} =
             Setup.init(
               "/nix/store/no-janitor-secrets",
               "owner@example.com",
               "https://example.com"
             )
  end

  test "doctor reports pending OAuth/mail/token setup honestly and emits no secrets", ctx do
    assert {:ok, _} =
             Setup.init(ctx.directory, "owner@example.com", "https://janitor.example.com")

    {:ok, env} = Setup.load_settings(Path.join(ctx.directory, "settings.json"))
    assert {:ok, result} = Setup.doctor(env, database_probe: fn _ -> :ok end)
    assert result.checks.configuration == :ready
    assert result.checks.google_oauth == :not_configured
    assert result.checks.mail_transport == :not_configured
    refute result.local_ready
    refute result.processing_ready
    assert result.cloud_checks == :not_run
    refute inspect(result) =~ File.read!(env["JANITOR_SECRET_KEY_BASE_FILE"])

    assert {:ok, %{local_ready: false}} =
             Setup.doctor(Map.put(env, "JANITOR_MODEL_PROVIDER", "azure"))
  end

  test "doctor validates actual shared adapters and a read-only local PostgreSQL probe", ctx do
    {:ok, _} = Setup.init(ctx.directory, "owner@example.com", "https://janitor.example.com")
    {:ok, env} = Setup.load_settings(Path.join(ctx.directory, "settings.json"))
    oauth = Path.join(ctx.directory, "google-client.json")

    File.write!(
      oauth,
      Jason.encode!(%{
        "web" => %{
          "client_id" => "fixture-client",
          "client_secret" => "SECRET_SENTINEL",
          "redirect_uris" => ["https://janitor.example.com/auth/google/callback"]
        }
      })
    )

    File.chmod!(oauth, 0o600)
    token = Path.join(ctx.directory, "token.json")

    File.write!(
      token,
      Jason.encode!(%{
        "access_token" => "TOKEN_SENTINEL_123",
        "expires_at" => System.system_time(:second) + 300
      })
    )

    File.chmod!(token, 0o600)

    env =
      Map.merge(env, %{
        "JANITOR_GOOGLE_CLIENT_JSON_FILE" => oauth,
        "JANITOR_GOOGLE_TOKEN_FILE" => token,
        "JANITOR_GOOGLE_PROJECT" => "emailjanitor-fixture",
        "JANITOR_GOOGLE_TOPIC" => "projects/emailjanitor-fixture/topics/changes",
        "JANITOR_GOOGLE_SUBSCRIPTION" => "projects/emailjanitor-fixture/subscriptions/changes",
        "JANITOR_MAIL_SENDER" => "janitor@mail.example.com",
        "JANITOR_MAIL_BUCKET" => "janitor-mail-fixture",
        "JANITOR_MAIL_QUEUE_URL" => "https://sqs.us-east-1.amazonaws.com/123456789012/fixture",
        "JANITOR_MAIL_TOPIC_ARN" => "arn:aws:sns:us-east-1:123456789012:fixture",
        "JANITOR_DATABASE_SOCKET" => System.fetch_env!("JANITOR_TEST_SOCKET"),
        "JANITOR_DATABASE_NAME" => "emailjanitor_test",
        "JANITOR_DATABASE_USER" => System.fetch_env!("USER")
      })

    assert {:ok, %{local_ready: true, processing_ready: false}} = Setup.doctor(env)
    File.write!(token, "{\"access_token\":\"SECRET_TOKEN\",\"expires_at\":0}")

    assert {:ok, %{local_ready: false, checks: %{google_service_token: :unavailable}}} =
             Setup.doctor(env, database_probe: fn _ -> :ok end)
  end

  test "doctor survives an absent database socket and reports unavailable without a crash trace",
       ctx do
    {:ok, _} = Setup.init(ctx.directory, "owner@example.com", "https://janitor.example.com")
    {:ok, env} = Setup.load_settings(Path.join(ctx.directory, "settings.json"))
    env = Map.put(env, "JANITOR_DATABASE_SOCKET", Path.join(ctx.parent, "nonexistent-socket"))
    started = System.monotonic_time(:millisecond)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{local_ready: false, checks: %{database: :unavailable}}} = Setup.doctor(env)
        assert Process.alive?(self())
      end)

    assert System.monotonic_time(:millisecond) - started < 5_500
    assert logs == ""
  end

  @provider "projects/123456789012/locations/global/workloadIdentityPools/janitor-pool/providers/aws-provider"
  @account "janitor-service@emailjanitor-fixture.iam.gserviceaccount.com"
  defp external_account(provider \\ @provider),
    do: %{
      "type" => "external_account",
      "audience" => "//iam.googleapis.com/" <> provider,
      "subject_token_type" => "urn:ietf:params:aws:token-type:aws4_request",
      "token_url" => "https://sts.googleapis.com/v1/token",
      "service_account_impersonation_url" =>
        "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" <>
          @account <> ":generateAccessToken",
      "credential_source" => %{
        "environment_id" => "aws1",
        "imdsv2_session_token_url" => "http://169.254.169.254/latest/api/token"
      }
    }

  test "WIF config delegates official gcloud with fixed AWS IMDSv2 arguments and isolated profile",
       ctx do
    owner = self()
    output = Path.join(ctx.parent, "aws.json")

    runner = fn executable, args, options ->
      assert executable == "/fixture/gcloud"

      assert Enum.take(args, 4) == [
               "iam",
               "workload-identity-pools",
               "create-cred-config",
               @provider
             ]

      assert "--aws" in args and "--enable-imdsv2" in args and "--quiet" in args
      assert ("--service-account=" <> @account) in args

      temporary =
        args
        |> Enum.find(&String.starts_with?(&1, "--output-file="))
        |> String.replace_prefix("--output-file=", "")

      assert options[:env] |> List.keyfind("CLOUDSDK_CORE_DISABLE_PROMPTS", 0) ==
               {"CLOUDSDK_CORE_DISABLE_PROMPTS", "1"}

      send(owner, {:temporary, Path.dirname(temporary)})
      File.write!(temporary, Jason.encode!(external_account()))
      {"PRIVATE_GCLOUD_OUTPUT_NOT_PRINTED", 0}
    end

    assert {:ok, %{path: ^output}} =
             Setup.wif_config(@provider, @account, output,
               gcloud: "/fixture/gcloud",
               runner: runner
             )

    assert {:temporary, temporary} = assert_received({:temporary, _})
    refute File.exists?(temporary)
    assert Jason.decode!(File.read!(output))["audience"] == "//iam.googleapis.com/" <> @provider
    assert Bitwise.band(File.stat!(output).mode, 0o777) == 0o600

    assert {:error, :invalid_wif_configuration} =
             Setup.wif_config(@provider, @account, output,
               gcloud: "/fixture/gcloud",
               runner: fn _, _, _ -> flunk("no overwrite") end
             )
  end

  test "WIF failures, altered audiences and missing IMDSv2 do not publish configuration", ctx do
    output = Path.join(ctx.parent, "aws.json")

    for value <- [
          Map.put(external_account(), "audience", "//altered"),
          put_in(external_account(), ["credential_source", "imdsv2_session_token_url"], nil)
        ] do
      runner = fn _, args, _ ->
        path =
          args
          |> Enum.find(&String.starts_with?(&1, "--output-file="))
          |> String.replace_prefix("--output-file=", "")

        File.write!(path, Jason.encode!(value))
        {"", 0}
      end

      assert {:error, :gcloud_configuration_failed} =
               Setup.wif_config(@provider, @account, output,
                 gcloud: "/fixture/gcloud",
                 runner: runner
               )

      refute File.exists?(output)
    end

    assert {:error, :gcloud_configuration_failed} =
             Setup.wif_config(@provider, @account, output,
               gcloud: "/fixture/gcloud",
               runner: fn _, _, _ -> {"PRIVATE_SECRET", 1} end
             )

    assert {:error, :invalid_wif_configuration} =
             Setup.wif_config(@provider <> "\n--evil", @account, output)

    assert {:error, :gcloud_unavailable} =
             Setup.wif_config(@provider, @account, output, gcloud: nil)
  end

  test "CLI rejects unknown/duplicate arguments and settings with credentials", ctx do
    assert :help = CLI.run(["--help"])

    for args <- [
          ["apply"],
          ["init", "--owner", "a", "--owner", "b"],
          ["doctor", "--enable"],
          ["wif-config", "--aws"]
        ] do
      assert {:error, :invalid_arguments} = CLI.run(args)
    end

    file = Path.join(ctx.parent, "unsafe.json")
    File.write!(file, Jason.encode!(%{"GOOGLE_ACCESS_TOKEN" => "SECRET"}))
    assert {:error, :invalid_setup_settings} = Setup.load_settings(file)

    assert ExUnit.CaptureIO.capture_io(:stderr, fn -> assert CLI.main_json("{broken") == 1 end) ==
             "Email Janitor setup: invalid_arguments\n"
  end
end
