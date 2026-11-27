defmodule EmailJanitor.SelfHostSkeletonTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias EmailJanitor.{Content, SelfHost}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.{Binding, Cipher, Config, Repo, Store}

  setup_all do
    start_supervised!(
      {Repo,
       socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
       database: "emailjanitor_test",
       username: System.fetch_env!("USER"),
       port: 5432,
       pool: Ecto.Adapters.SQL.Sandbox,
       pool_size: 8,
       log: false}
    )

    scope = SelfHost.scope()

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      EmailJanitor.Store.install(scope)
      EmailJanitor.Preferences.install(scope)
      EmailJanitor.Mail.Store.install(scope)
      EmailJanitor.Digest.install(scope)
      Store.install(scope)
    end)

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    old = Application.get_env(:email_janitor, :self_host_config)

    config = %Config{
      owner_email: "owner@example.com",
      public_url: "https://janitor.example.com",
      credential_key: Content.new(:crypto.strong_rand_bytes(32)),
      web_secret: Content.new(String.duplicate("s", 64))
    }

    Application.put_env(:email_janitor, :self_host_config, config)

    on_exit(fn ->
      if old,
        do: Application.put_env(:email_janitor, :self_host_config, old),
        else: Application.delete_env(:email_janitor, :self_host_config)
    end)

    %{scope: SelfHost.scope(), config: config}
  end

  defp result(subject \\ "owner-subject", email \\ "owner@example.com") do
    %OAuth.Result{
      subject: subject,
      email: email,
      token:
        Content.new(
          Jason.encode!(%{
            "access_token" => "PRIVATE_GOOGLE_ACCESS_SENTINEL",
            "refresh_token" => "PRIVATE_GOOGLE_REFRESH_SENTINEL",
            "token_type" => "Bearer",
            "expires_at" => System.system_time(:second) + 3600,
            "scope" => "openid email https://www.googleapis.com/auth/gmail.modify"
          })
        )
    }
  end

  test "initial verified owner email pins an immutable Google subject" do
    refute SelfHost.owner?("other")

    assert {:error, :unauthorized} =
             SelfHost.authorize_owner(result("other", "other@example.com"))

    assert {:ok, "owner-subject"} = SelfHost.authorize_owner(result())
    assert SelfHost.owner?("owner-subject")

    assert {:ok, "owner-subject"} =
             SelfHost.authorize_owner(result("owner-subject", "renamed@example.com"))

    assert {:error, :unauthorized} =
             SelfHost.authorize_owner(result("other", "owner@example.com"))

    refute SelfHost.owner?("other")
    assert {:error, :unauthorized} = SelfHost.inboxes("other")
    assert {:error, :unauthorized} = SelfHost.status("other")
  end

  test "multiple inbox credentials stay encrypted and disconnect fences prepared work", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    initial_result = result()
    assert {:ok, first} = SelfHost.connect(owner, initial_result, "America/Los_Angeles")

    assert {:ok, second} =
             SelfHost.connect(owner, result("work-subject", "work@example.com"), "Etc/UTC")

    refute first.id == second.id
    assert {:ok, [%{state: :pending}, %{state: :pending}]} = SelfHost.inboxes(owner)
    assert {:ok, ^first} = SelfHost.inbox(owner, first.id)
    assert {:ok, %{scope: scope, inbox: ^first}} = SelfHost.conversation_context(owner, first.id)
    assert scope == ctx.scope
    saved = Repo.get!(Binding, first.id, prefix: scope.prefix)
    refute saved.token_ciphertext =~ "PRIVATE_GOOGLE"
    refute inspect(saved) =~ saved.token_ciphertext
    assert {:ok, token} = SelfHost.open("gmail-token", first.id, saved.token_ciphertext)
    assert Content.read(token) == Content.read(initial_result.token)
    {:ok, before} = EmailJanitor.Store.instruction_version(scope, first.id)
    assert :ok = SelfHost.disconnect(owner, first.id)
    assert {:ok, after_version} = EmailJanitor.Store.instruction_version(scope, first.id)
    assert after_version == before + 1
    assert Repo.get!(Binding, first.id, prefix: scope.prefix).token_ciphertext == nil
    assert {:error, :inbox_unavailable} = SelfHost.inbox(owner, first.id)
    assert :ok = SelfHost.disconnect(owner, first.id)
    assert {:ok, ^after_version} = EmailJanitor.Store.instruction_version(scope, first.id)
    assert {:ok, ^second} = SelfHost.inbox(owner, second.id)
    assert {:error, :unauthorized} = SelfHost.connect("other", result(), "Etc/UTC")
    assert {:error, :unauthorized} = SelfHost.disconnect("other", second.id)
  end

  test "connection validates credentials and timezone before any durable binding", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    assert {:error, :invalid_connection} = SelfHost.connect(owner, result(), "Invalid/Timezone")

    assert {:error, :invalid_connection} =
             SelfHost.connect(
               owner,
               %{result() | token: Content.new("PRIVATE_RAW_BODY")},
               "Etc/UTC"
             )

    data = Jason.decode!(Content.read(result().token)) |> Map.put("body", "PRIVATE_EMAIL_BODY")

    assert {:error, :invalid_connection} =
             SelfHost.connect(
               owner,
               %{result() | token: Content.new(Jason.encode!(data))},
               "Etc/UTC"
             )

    assert Repo.aggregate(from(b in Binding), :count, prefix: ctx.scope.prefix) == 0
  end

  test "AEAD binds each ciphertext to its purpose and opaque row ID", ctx do
    content = Content.new("PRIVATE_OAUTH_ATTEMPT_SENTINEL")
    assert {:ok, first} = SelfHost.seal("browser-oauth", "id1", content)
    assert {:ok, second} = SelfHost.seal("browser-oauth", "id1", content)
    refute first == second
    assert {:ok, plaintext} = SelfHost.open("browser-oauth", "id1", first)
    assert Content.read(plaintext) == Content.read(content)
    assert {:error, :credential_open_failed} = SelfHost.open("browser-oauth", "id2", first)
    assert {:error, :credential_open_failed} = SelfHost.open("gmail-token", "id1", first)

    assert {:error, :credential_open_failed} =
             Cipher.open(
               Content.new(:crypto.strong_rand_bytes(32)),
               "browser-oauth",
               "id1",
               first
             )

    <<head, tail::binary>> = first

    assert {:error, :credential_open_failed} =
             SelfHost.open("browser-oauth", "id1", <<head + 1, tail::binary>>)

    size = byte_size(first) - 1
    <<prefix::binary-size(size), last>> = first

    assert {:error, :credential_open_failed} =
             SelfHost.open("browser-oauth", "id1", <<prefix::binary, Bitwise.bxor(last, 1)>>)

    assert {:error, :credential_seal_failed} =
             Cipher.seal(ctx.config.credential_key, "", "id1", content)

    assert {:error, :credential_seal_failed} =
             SelfHost.seal("browser-oauth", "id1", Content.new(String.duplicate("x", 65_537)))
  end
end
