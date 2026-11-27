defmodule EmailJanitor.SelfHostSkeletonTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias EmailJanitor.{Content, SelfHost}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.{Binding, Cipher, Config, Credentials, Repo, Store}

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
      EmailJanitor.Gmail.Ingestion.install(scope)
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

  defp with_token(result, changes) do
    data = Jason.decode!(Content.read(result.token)) |> Map.merge(changes)
    %{result | token: Content.new(Jason.encode!(data))}
  end

  defp refresh_fixture(ctx, callback) do
    {:ok, oauth} =
      OAuth.Config.new(
        "synthetic-client",
        "PRIVATE_OAUTH_CLIENT_SECRET",
        "https://janitor.example.com/auth/google/callback"
      )

    Req.Test.stub(:self_host_refresh, callback)

    Application.put_env(:email_janitor, :self_host_config, %{
      ctx.config
      | google_oauth: %{oauth | http_options: [plug: {Req.Test, :self_host_refresh}]}
    })
  end

  test "each resolver uses only its own scoped encrypted token and rejects stale epochs", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, first} = SelfHost.connect(owner, result(), "Etc/UTC")

    second_result =
      with_token(result("work", "work@example.com"), %{
        "access_token" => "PRIVATE_OTHER_ACCOUNT_TOKEN"
      })

    {:ok, second} = SelfHost.connect(owner, second_result, "Etc/UTC")
    first_binding = Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)
    second_binding = Repo.get!(Binding, second.id, prefix: ctx.scope.prefix)
    assert {:ok, a} = Credentials.token({first.id, first_binding.epoch})
    assert {:ok, b} = Credentials.token({second.id, second_binding.epoch})
    assert Content.read(a) == "PRIVATE_GOOGLE_ACCESS_SENTINEL"
    assert Content.read(b) == "PRIVATE_OTHER_ACCOUNT_TOKEN"

    assert {:error, :google_credentials_unavailable} =
             Credentials.token({first.id, first_binding.epoch + 1})

    assert :ok = Store.activate({first.id, first_binding.epoch})
    assert :ok = Store.guard({first.id, first_binding.epoch}, first)
  end

  test "the real scheduler accepts bounded binary references and rejects a disconnected epoch",
       _ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, box} = SelfHost.connect(owner, result(), "Etc/UTC")
    assert {:ok, [key]} = Store.worker_refs()
    assert is_binary(key) and byte_size(key) in 1..256
    assert {:ok, binding, ^box} = Store.fetch_binding(key)
    assert key != box.id
    observer = self()

    EmailJanitor.TestScheduler.start_cleanup(
      list: &Store.worker_refs/0,
      resolve: fn reference ->
        send(observer, {:scheduler_resolved, reference})
        {:error, :synthetic_stop}
      end,
      max_concurrency: 1,
      interval_ms: 10
    )

    assert_receive {:scheduler_resolved, ^key}, 5_000
    assert {:ok, ^binding, ^box} = Store.fetch_binding(key)
    assert :ok = disconnect_and_complete(owner, box.id)
    assert {:error, :inbox_unavailable} = Store.fetch_binding(key)
    assert {:error, :inbox_unavailable} = Store.fetch_binding("not-a-binding-key")
  end

  test "real Google OAuth SDK refresh preserves the grant without changing connection epoch",
       ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    old = with_token(result(), %{"expires_at" => System.system_time(:second) + 30})
    {:ok, box} = SelfHost.connect(owner, old, "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    parent = self()

    refresh_fixture(ctx, fn conn ->
      assert conn.host == "oauth2.googleapis.com"
      assert conn.request_path == "/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == "PRIVATE_GOOGLE_REFRESH_SENTINEL"
      send(parent, :refreshed_once)

      Req.Test.json(conn, %{
        "access_token" => "PRIVATE_REFRESHED_ACCESS_SENTINEL",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })
    end)

    assert {:ok, token} = Credentials.token({box.id, before.epoch})
    assert Content.read(token) == "PRIVATE_REFRESHED_ACCESS_SENTINEL"
    assert_receive :refreshed_once
    after_binding = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert after_binding.epoch == before.epoch
    assert after_binding.token_version == before.token_version + 1
    assert {:ok, content} = SelfHost.open("gmail-token", box.id, after_binding.token_ciphertext)

    assert Jason.decode!(Content.read(content))["refresh_token"] ==
             "PRIVATE_GOOGLE_REFRESH_SENTINEL"

    assert {:ok, _} = Credentials.token({box.id, before.epoch})
    refute_receive :refreshed_once
  end

  test "a refresh in flight cannot republish credentials after disconnect", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    old = with_token(result(), %{"expires_at" => System.system_time(:second) + 30})
    {:ok, box} = SelfHost.connect(owner, old, "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    parent = self()

    refresh_fixture(ctx, fn conn ->
      send(parent, {:refresh_waiting, self()})

      receive do
        :continue -> :ok
      after
        5000 -> flunk("refresh barrier expired")
      end

      Req.Test.json(conn, %{
        "access_token" => "PRIVATE_STALE_REFRESHED_TOKEN",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })
    end)

    task = Task.async(fn -> Credentials.token({box.id, before.epoch}) end)
    assert_receive {:refresh_waiting, callback}, 5000
    assert :ok = disconnect_and_complete(owner, box.id)
    send(callback, :continue)
    assert {:error, :google_credentials_unavailable} = Task.await(task, 5000)
    assert :ok = complete_revocations()
    saved = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert saved.state == :disconnected
    assert saved.token_ciphertext == nil
    assert saved.epoch > before.epoch
    assert {:error, :inbox_unavailable} = Store.guard({box.id, before.epoch}, box)
  end

  test "a revoked refresh grant clears credentials and invalidates prepared work", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    old = with_token(result(), %{"expires_at" => System.system_time(:second) + 30})
    {:ok, box} = SelfHost.connect(owner, old, "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    {:ok, version} = EmailJanitor.Store.instruction_version(ctx.scope, box.id)

    refresh_fixture(ctx, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, :reauthorization_required} = Credentials.token({box.id, before.epoch})
    saved = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert saved.state == :reauthorization_required
    assert saved.token_ciphertext == nil
    assert saved.epoch == before.epoch + 1
    assert {:ok, next} = EmailJanitor.Store.instruction_version(ctx.scope, box.id)
    assert next == version + 1
    assert {:ok, ^box} = SelfHost.connect(owner, result(), "Etc/UTC")
    reauthorized = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert reauthorized.epoch == saved.epoch
    assert reauthorized.state == :pending
    refute reauthorized.reset_baseline
  end

  test "only deliberate disconnect/reconnect requests a new baseline until activation commits",
       ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, box} = SelfHost.connect(owner, result(), "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    refute before.reset_baseline
    assert :ok = Store.activate({box.id, before.epoch})
    assert :ok = disconnect_and_complete(owner, box.id)
    assert {:ok, ^box} = SelfHost.connect(owner, result(), "Etc/UTC")
    reconnected = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert reconnected.reset_baseline
    assert reconnected.state == :pending
    assert reconnected.epoch > before.epoch
    assert {:ok, ^box} = SelfHost.connect(owner, result(), "Etc/UTC")
    assert Repo.get!(Binding, box.id, prefix: ctx.scope.prefix).reset_baseline
    assert {:error, :baseline_activation_required} = Store.activate({box.id, reconnected.epoch})
    assert Repo.get!(Binding, box.id, prefix: ctx.scope.prefix).reset_baseline
  end

  test "reconnect checkpoint and binding activation recover atomically after a failed callback",
       ctx do
    alias EmailJanitor.Gmail.Ingestion
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, box} = SelfHost.connect(owner, result(), "Etc/UTC")
    first = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    watch = %{history_id: "100", expires_at: DateTime.add(DateTime.utc_now(), 3600)}

    assert {:ok, original} =
             Ingestion.baseline(ctx.scope, box, watch,
               on_baseline: fn _ -> Store.activate({box.id, first.epoch}) end
             )

    :ok = disconnect_and_complete(owner, box.id)
    {:ok, ^box} = SelfHost.connect(owner, result(), "Etc/UTC")
    fresh = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    ref = {box.id, fresh.epoch}
    {:ok, version} = EmailJanitor.Store.instruction_version(ctx.scope, box.id)

    assert {:error, :activation_failed} =
             Ingestion.activate(ctx.scope, box, original.generation,
               expected_instruction_version: version,
               on_baseline: fn _ -> Store.activate(ref) end
             )

    assert %{state: :pending, reset_baseline: true, reset_generation: generation} =
             Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)

    assert generation == original.generation
    new_watch = %{watch | history_id: "200"}

    assert {:error, :activation_failed} =
             Ingestion.reconnect(ctx.scope, box, original.generation, new_watch,
               expected_instruction_version: version,
               on_baseline: fn _ ->
                 :ok = Store.activate(ref)
                 raise "simulated process failure before commit"
               end
             )

    assert {:ok, checkpoint} = Ingestion.checkpoint(ctx.scope, box.id)
    assert checkpoint.generation == original.generation
    assert checkpoint.cursor == "100"

    assert %{state: :pending, reset_baseline: true} =
             Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)

    assert {:ok, next} =
             Ingestion.reconnect(ctx.scope, box, original.generation, new_watch,
               expected_instruction_version: version,
               on_baseline: fn _ -> Store.activate(ref) end
             )

    refute next.generation == original.generation
    assert next.cursor == "200"

    assert %{state: :active, reset_baseline: false} =
             Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)

    assert {:ok, :ok} = Ingestion.record_signal(ctx.scope, box, "201")

    assert {:ok, resumed} =
             Ingestion.activate(ctx.scope, box, next.generation,
               expected_instruction_version: version,
               on_baseline: fn _ -> Store.activate(ref) end
             )

    assert resumed.generation == next.generation
    assert resumed.cursor == "200"
    assert resumed.requested_id == "201"
  end

  test "late refresh cannot overwrite newer consent even when the connection epoch is preserved",
       ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    old = with_token(result(), %{"expires_at" => System.system_time(:second) + 30})
    {:ok, box} = SelfHost.connect(owner, old, "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    parent = self()

    refresh_fixture(ctx, fn conn ->
      send(parent, {:refresh_waiting, self()})

      receive do
        :continue -> :ok
      after
        5000 -> flunk("refresh barrier expired")
      end

      Req.Test.json(conn, %{
        "access_token" => "PRIVATE_STALE_REFRESHED_TOKEN",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })
    end)

    task = Task.async(fn -> Credentials.token({box.id, before.epoch}) end)
    assert_receive {:refresh_waiting, callback}, 5000
    consent = with_token(result(), %{"access_token" => "PRIVATE_NEW_CONSENT_TOKEN"})
    assert {:ok, ^box} = SelfHost.connect(owner, consent, "Etc/UTC")
    send(callback, :continue)
    assert {:ok, current} = Task.await(task, 5000)
    assert Content.read(current) == "PRIVATE_NEW_CONSENT_TOKEN"
    saved = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert saved.epoch == before.epoch
    assert saved.token_version == before.token_version + 1
    assert {:ok, content} = SelfHost.open("gmail-token", box.id, saved.token_ciphertext)
    assert Jason.decode!(Content.read(content))["access_token"] == "PRIVATE_NEW_CONSENT_TOKEN"
  end

  test "concurrent refresh callers both receive the winning valid token", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    old = with_token(result(), %{"expires_at" => System.system_time(:second) + 30})
    {:ok, box} = SelfHost.connect(owner, old, "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    parent = self()

    refresh_fixture(ctx, fn conn ->
      send(parent, {:refresh_waiting, self()})

      receive do
        :continue -> :ok
      after
        5000 -> flunk("refresh barrier expired")
      end

      Req.Test.json(conn, %{
        "access_token" => "PRIVATE_WINNING_REFRESH_TOKEN",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })
    end)

    tasks = for _ <- 1..2, do: Task.async(fn -> Credentials.token({box.id, before.epoch}) end)
    assert_receive {:refresh_waiting, first}, 5000
    assert_receive {:refresh_waiting, second}, 5000
    send(first, :continue)
    send(second, :continue)

    for task <- tasks do
      assert {:ok, token} = Task.await(task, 5000)
      assert Content.read(token) == "PRIVATE_WINNING_REFRESH_TOKEN"
    end

    assert Repo.get!(Binding, box.id, prefix: ctx.scope.prefix).token_version ==
             before.token_version + 1

    refute_receive {:refresh_waiting, _}
  end

  test "a stale invalid-grant response uses newer consent without asking for reconnect", ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    old = with_token(result(), %{"expires_at" => System.system_time(:second) + 30})
    {:ok, box} = SelfHost.connect(owner, old, "Etc/UTC")
    before = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    parent = self()

    refresh_fixture(ctx, fn conn ->
      send(parent, {:refresh_waiting, self()})

      receive do
        :continue -> :ok
      after
        5000 -> flunk("refresh barrier expired")
      end

      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    task = Task.async(fn -> Credentials.token({box.id, before.epoch}) end)
    assert_receive {:refresh_waiting, callback}, 5000
    consent = with_token(result(), %{"access_token" => "PRIVATE_NEW_CONSENT_TOKEN"})
    assert {:ok, ^box} = SelfHost.connect(owner, consent, "Etc/UTC")
    send(callback, :continue)
    assert {:ok, token} = Task.await(task, 5000)
    assert Content.read(token) == "PRIVATE_NEW_CONSENT_TOKEN"
    saved = Repo.get!(Binding, box.id, prefix: ctx.scope.prefix)
    assert saved.state == before.state
    assert saved.epoch == before.epoch
    assert saved.token_version == before.token_version + 1
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
    assert :ok = disconnect_and_complete(owner, first.id)
    assert {:ok, after_version} = EmailJanitor.Store.instruction_version(scope, first.id)
    assert after_version == before + 1
    assert Repo.get!(Binding, first.id, prefix: scope.prefix).token_ciphertext == nil
    assert {:error, :inbox_unavailable} = SelfHost.inbox(owner, first.id)
    assert :ok = disconnect_and_complete(owner, first.id)
    assert {:ok, ^after_version} = EmailJanitor.Store.instruction_version(scope, first.id)
    assert {:ok, ^second} = SelfHost.inbox(owner, second.id)
    assert {:error, :unauthorized} = SelfHost.connect("other", result(), "Etc/UTC")
    assert {:error, :unauthorized} = disconnect_and_complete("other", second.id)
  end

  test "invalid token shapes never persist; valid rejected grants remain captured for retirement",
       ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())

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
    assert {:error, :invalid_connection} = SelfHost.connect(owner, result(), "Invalid/Timezone")

    assert [%{state: :revoking, token_ciphertext: nil}] =
             Repo.all(Binding, prefix: ctx.scope.prefix)

    assert :ok = complete_revocations()
    expired = with_token(result(), %{"expires_at" => System.system_time(:second) - 1})
    assert {:error, :invalid_connection} = SelfHost.connect(owner, expired, "Etc/UTC")

    assert {:error, :invalid_connection} =
             SelfHost.connect(owner, %{result() | subject: "bad subject"}, "Etc/UTC")
  end

  test "same verified address with a different Google subject gets a different immutable inbox",
       ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, first} = SelfHost.connect(owner, result("work-one", "work@example.com"), "Etc/UTC")
    {:ok, second} = SelfHost.connect(owner, result("work-two", "work@example.com"), "Etc/UTC")
    refute first.id == second.id
    assert Repo.get!(Binding, first.id, prefix: ctx.scope.prefix).google_subject == "work-one"
    assert Repo.get!(Binding, second.id, prefix: ctx.scope.prefix).google_subject == "work-two"
    assert :ok = complete_revocations()
    assert Repo.get!(Binding, first.id, prefix: ctx.scope.prefix).state == :disconnected
    assert Repo.get!(Binding, first.id, prefix: ctx.scope.prefix).token_ciphertext == nil
    {:ok, repeated} = SelfHost.connect(owner, result("work-one", "work@example.com"), "Etc/UTC")
    assert repeated.id == first.id
    assert Repo.get!(Binding, first.id, prefix: ctx.scope.prefix).google_subject == "work-one"
  end

  test "same-subject readdress preserves its inbox identity and fences prepared old-address work",
       ctx do
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, first} = SelfHost.connect(owner, result("work-one", "work@example.com"), "Etc/UTC")
    old = Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)
    alias EmailJanitor.Gmail.Ingestion.Checkpoint

    checkpoint =
      Repo.insert!(
        %Checkpoint{
          inbox_id: first.id,
          address: first.address,
          generation: Ecto.UUID.generate(),
          generation_started_at: DateTime.utc_now(),
          baseline_id: "100",
          cursor: "123",
          requested_id: "123",
          watch_expires_at: DateTime.add(DateTime.utc_now(), 86400),
          status: :active
        },
        prefix: ctx.scope.prefix
      )

    {:ok, version} = EmailJanitor.Store.instruction_version(ctx.scope, first.id)

    {:ok, renamed} =
      SelfHost.connect(owner, result("work-one", "new-work@example.com"), "Etc/UTC")

    assert renamed.id == first.id
    assert renamed.address == "new-work@example.com"
    assert {:ok, ^renamed} = SelfHost.inbox(owner, first.id)
    fresh = Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)
    assert fresh.google_subject == old.google_subject
    assert fresh.epoch == old.epoch + 1
    assert {:ok, next} = EmailJanitor.Store.instruction_version(ctx.scope, first.id)
    assert next == version + 1
    kept = Repo.get!(Checkpoint, first.id, prefix: ctx.scope.prefix)
    assert kept.address == renamed.address
    assert kept.cursor == checkpoint.cursor
    assert kept.baseline_id == checkpoint.baseline_id
    assert kept.generation == checkpoint.generation
    assert {:ok, :ok} = EmailJanitor.Gmail.Ingestion.record_signal(ctx.scope, renamed, "124")
  end

  test "replacing a revoked subject also fences its recorded old generation", ctx do
    alias EmailJanitor.Gmail.Ingestion
    {:ok, owner} = SelfHost.authorize_owner(result())
    first_result = result("work-one", "work@example.com")
    expiring = with_token(first_result, %{"expires_at" => System.system_time(:second) + 30})
    {:ok, first} = SelfHost.connect(owner, expiring, "Etc/UTC")
    binding = Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)

    assert {:ok, original} =
             Ingestion.baseline(
               ctx.scope,
               first,
               %{history_id: "100", expires_at: DateTime.add(DateTime.utc_now(), 3600)},
               on_baseline: fn _ -> Store.activate({first.id, binding.epoch}) end
             )

    refresh_fixture(ctx, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    assert {:error, :reauthorization_required} = Credentials.token({first.id, binding.epoch})
    {:ok, _other} = SelfHost.connect(owner, result("work-two", "work@example.com"), "Etc/UTC")

    assert %{state: :disconnected, reset_baseline: true, reset_generation: generation} =
             Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)

    assert generation == original.generation
    {:ok, ^first} = SelfHost.connect(owner, first_result, "Etc/UTC")
    rebound = Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)

    assert {:error, :activation_failed} =
             Ingestion.activate(ctx.scope, first, original.generation,
               on_baseline: fn _ -> Store.activate({first.id, rebound.epoch}) end
             )

    assert %{state: :pending, reset_baseline: true} =
             Repo.get!(Binding, first.id, prefix: ctx.scope.prefix)
  end

  test "self delivery retains verified historical address evidence only for the same subject",
       ctx do
    alias EmailJanitor.Mail.{Outbox, Outgoing}
    {:ok, owner} = SelfHost.authorize_owner(result())
    {:ok, first} = SelfHost.connect(owner, result("work-one", "old-work@example.com"), "Etc/UTC")

    {:ok, outgoing} =
      Outbox.enqueue(
        ctx.scope,
        first.id,
        :assistant,
        [Ecto.UUID.generate()],
        Ecto.UUID.generate()
      )

    Repo.update!(
      Ecto.Changeset.change(outgoing,
        state: :sent,
        provider_id: "historical-proof",
        sender: "janitor@janitor.example.com",
        recipient: first.address
      ),
      prefix: ctx.scope.prefix
    )

    headers = [
      {"From", "janitor@janitor.example.com"},
      {"Message-ID", "<historical-proof@email.amazonses.com>"}
    ]

    assert {:ok, true} = Store.self_delivery?(first.id, "janitor@janitor.example.com", headers)

    {:ok, renamed} =
      SelfHost.connect(owner, result("work-one", "new-work@example.com"), "Etc/UTC")

    assert renamed.id == first.id

    assert {:ok, false} =
             Outbox.self_delivery?(ctx.scope, first.id, "janitor@janitor.example.com", headers)

    assert {:ok, true} = Store.self_delivery?(first.id, "janitor@janitor.example.com", headers)

    {:ok, replacement} =
      SelfHost.connect(owner, result("work-two", "old-work@example.com"), "Etc/UTC")

    refute replacement.id == first.id

    assert {:ok, false} =
             Store.self_delivery?(replacement.id, "janitor@janitor.example.com", headers)

    Repo.update_all(
      from(o in Outgoing, where: o.id == ^outgoing.id),
      [set: [recipient: "unrecorded@example.net"]],
      prefix: ctx.scope.prefix
    )

    assert {:ok, false} = Store.self_delivery?(first.id, "janitor@janitor.example.com", headers)
  end

  test "selfhost installer cannot modify a different repository or schema", ctx do
    assert {:error, :invalid_self_host_scope} =
             Store.install(%{ctx.scope | prefix: "ej_unrelated"})

    assert {:error, :invalid_self_host_scope} =
             Store.install(%{ctx.scope | repo: EmailJanitor.TestRepo})

    assert {:error, :invalid_self_host_scope} = Store.install(nil)
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

  # These older lifecycle tests assert the completed-disconnect state. Provider
  # calls remain synthetic; pending/crash/identity fences are covered separately.
  defp disconnect_and_complete(owner, id) do
    case SelfHost.disconnect(owner, id) do
      :ok -> complete_revocations()
      other -> other
    end
  end

  defp complete_revocations do
    case EmailJanitor.SelfHost.Revocations.tick(SelfHost.config().google_oauth,
           revoke: fn _, _ -> :ok end
         ) do
      {:ok, :idle} -> :ok
      {:ok, _} -> complete_revocations()
      error -> flunk("synthetic grant retirement failed: #{inspect(error)}")
    end
  end
end
