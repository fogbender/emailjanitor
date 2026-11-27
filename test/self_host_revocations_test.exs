defmodule EmailJanitor.SelfHostRevocationsTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, SelfHost}
  alias EmailJanitor.Google.OAuth

  alias EmailJanitor.SelfHost.{
    Binding,
    Config,
    Credentials,
    GoogleGrant,
    Repo,
    Revocation,
    Revocations,
    Store
  }

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

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      EmailJanitor.Store.install(SelfHost.scope())
      EmailJanitor.Preferences.install(SelfHost.scope())
      EmailJanitor.Mail.Store.install(SelfHost.scope())
      EmailJanitor.Digest.install(SelfHost.scope())
      EmailJanitor.Gmail.Ingestion.install(SelfHost.scope())
      Store.install(SelfHost.scope())
    end)

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:email_janitor, :self_host_config)

    {:ok, oauth} =
      OAuth.Config.new("synthetic-client", "secret", "http://127.0.0.1/auth/google/callback")

    config = %Config{
      owner_email: "owner@example.com",
      public_url: "http://127.0.0.1",
      google_oauth: oauth,
      credential_key: Content.new(:crypto.strong_rand_bytes(32)),
      web_secret: Content.new(String.duplicate("s", 64))
    }

    Application.put_env(:email_janitor, :self_host_config, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:email_janitor, :self_host_config, previous),
        else: Application.delete_env(:email_janitor, :self_host_config)
    end)

    result = %OAuth.Result{
      subject: "owner-subject",
      email: "owner@example.com",
      token:
        Content.new(
          Jason.encode!(%{
            access_token: "PRIVATE_REVOKE_ACCESS_SENTINEL",
            refresh_token: "PRIVATE_REVOKE_REFRESH_SENTINEL",
            expires_at: System.system_time(:second) + 3600,
            token_type: "Bearer",
            scope: "https://www.googleapis.com/auth/gmail.modify"
          })
        )
    }

    {:ok, owner} = SelfHost.authorize_owner(result)
    {:ok, inbox} = SelfHost.connect(owner, result, "Etc/UTC")
    %{scope: SelfHost.scope(), inbox: inbox, owner: owner, result: result, config: config}
  end

  defp saved(ctx), do: Repo.get!(Revocation, ctx.inbox.id, prefix: ctx.scope.prefix)
  defp host_binding(ctx), do: Repo.get!(Binding, ctx.inbox.id, prefix: ctx.scope.prefix)

  test "disconnect atomically fences local work, preserves encrypted retirement capability and blocks fresh consent",
       ctx do
    before = host_binding(ctx)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    pending = saved(ctx)
    assert pending.state == :pending
    assert pending.token_ciphertext == before.token_ciphertext
    assert {:ok, token} = SelfHost.open("gmail-token", ctx.inbox.id, pending.token_ciphertext)
    assert Content.read(token) == Content.read(ctx.result.token)
    refute inspect(pending) =~ "PRIVATE_REVOKE"
    assert host_binding(ctx).state == :revoking and host_binding(ctx).token_ciphertext == nil
    assert host_binding(ctx).epoch == before.epoch + 1

    assert {:error, :google_credentials_unavailable} =
             Credentials.token({ctx.inbox.id, before.epoch})

    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    assert saved(ctx).request_id == pending.request_id
    assert host_binding(ctx).epoch == before.epoch + 1
  end

  test "a live revoker holds the subject fence through helper completion and atomic erasure",
       ctx do
    :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    observer = self()

    task =
      Task.async(fn ->
        Revocations.tick(ctx.config.google_oauth,
          revoke: fn _, token ->
            refute Repo.in_transaction?()

            assert Jason.decode!(Content.read(token))["refresh_token"] ==
                     "PRIVATE_REVOKE_REFRESH_SENTINEL"

            send(observer, {:revoking, self()})

            receive do
              :complete -> :ok
            end
          end
        )
      end)

    assert_receive {:revoking, owner}, 5_000
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               now: DateTime.add(DateTime.utc_now(), 3600),
               revoke: fn _, _ -> flunk("live owner cannot be bypassed by a clock jump") end
             )

    send(owner, :complete)
    assert {:ok, :retirement_continues} = Task.await(task, 5_000)
    assert {:ok, :revoked} = Revocations.tick(ctx.config.google_oauth, revoke: fn _, _ -> :ok end)
    assert saved(ctx).state == :complete and saved(ctx).outcome == :revoked
    assert saved(ctx).token_ciphertext == nil and saved(ctx).owner_token == nil
    assert host_binding(ctx).state == :disconnected
    assert {:ok, _} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("completed old grant must never revoke again") end
             )
  end

  test "transient failures retain capability and exact invalid-token completion reports only unusable local access",
       ctx do
    :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)

    assert {:ok, :retry_scheduled} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> {:error, :revocation_unavailable} end
             )

    assert saved(ctx).state == :pending and saved(ctx).attempts == 1
    assert is_binary(saved(ctx).token_ciphertext)
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("must preserve backoff") end
             )

    assert {:ok, :retirement_continues} =
             Revocations.tick(ctx.config.google_oauth,
               now: DateTime.add(DateTime.utc_now(), 61),
               revoke: fn _, _ -> {:error, :refresh_token_invalid} end
             )

    assert {:ok, :credential_unusable} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> {:error, :refresh_token_invalid} end
             )

    assert saved(ctx).state == :complete and saved(ctx).outcome == :refresh_token_invalid
    assert saved(ctx).token_ciphertext == nil
    assert host_binding(ctx).state == :disconnected
    assert {:ok, _} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
  end

  test "post-wire owner death requires physical quarantine even after a forward wall-clock jump",
       ctx do
    :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    observer = self()

    task =
      Task.async(fn ->
        Revocations.tick(ctx.config.google_oauth,
          revoke: fn _, _ ->
            send(observer, {:remote_accepted, self()})
            Process.exit(self(), :kill)
          end
        )
      end)

    assert_receive {:remote_accepted, dead_owner}, 5_000
    assert {:error, :executor_unavailable} = Task.await(task, 5_000)
    refute Process.alive?(dead_owner)
    row = saved(ctx)
    assert row.state == :processing and EmailJanitor.Owner.proof(row) == :dead
    assert DateTime.diff(row.next_attempt_at, row.updated_at, :second) >= 119

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               now: DateTime.add(DateTime.utc_now(), 45),
               revoke: fn _, _ -> flunk("last-started helper may still be alive") end
             )

    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")

    started = System.monotonic_time(:millisecond)

    recovery =
      Task.async(fn ->
        Revocations.tick(ctx.config.google_oauth,
          now: DateTime.add(DateTime.utc_now(), 3600),
          revoke: fn _, _ ->
            send(observer, :recovery_provider_call)
            :ok
          end
        )
      end)

    refute_receive :recovery_provider_call, 100
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
    assert {:ok, :retirement_continues} = Task.await(recovery, 25_000)
    assert {:ok, :revoked} = Revocations.tick(ctx.config.google_oauth, revoke: fn _, _ -> :ok end)
    assert_receive :recovery_provider_call
    assert System.monotonic_time(:millisecond) - started >= 20_000

    assert saved(ctx).token_ciphertext == nil
    assert {:ok, _} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
  end

  test "the project-wide subject fence also rejects a different OAuth client and address", ctx do
    :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    other = %{ctx.config.google_oauth | client_id: "another-client-same-project"}
    Application.put_env(:email_janitor, :self_host_config, %{ctx.config | google_oauth: other})

    assert {:error, :revocation_pending} =
             SelfHost.connect(ctx.owner, %{ctx.result | email: "renamed@example.com"}, "Etc/UTC")

    assert {:ok, _} =
             SelfHost.connect(
               ctx.owner,
               %{ctx.result | subject: "different-subject", email: "other@example.com"},
               "Etc/UTC"
             )
  end

  test "already-rejected erased credentials can finish locally, while unexplained missing capabilities stay explicit",
       ctx do
    Repo.delete_all(GoogleGrant, prefix: ctx.scope.prefix)

    Repo.update!(
      Ecto.Changeset.change(host_binding(ctx),
        state: :reauthorization_required,
        token_ciphertext: nil
      ),
      prefix: ctx.scope.prefix
    )

    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    assert saved(ctx).state == :complete and saved(ctx).outcome == :credential_unusable
    assert host_binding(ctx).state == :disconnected
    assert {:ok, _} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")

    Repo.delete_all(GoogleGrant, prefix: ctx.scope.prefix)

    Repo.update!(Ecto.Changeset.change(host_binding(ctx), token_ciphertext: nil),
      prefix: ctx.scope.prefix
    )

    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    assert saved(ctx).state == :manual_required and saved(ctx).outcome == :missing_token
    assert host_binding(ctx).state == :revocation_required
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("no token to revoke") end
             )
  end

  test "only an exact local operator attestation releases a missing-token fence; stale repeats preserve new consent",
       ctx do
    Repo.delete_all(GoogleGrant, prefix: ctx.scope.prefix)

    Repo.update!(Ecto.Changeset.change(host_binding(ctx), token_ciphertext: nil),
      prefix: ctx.scope.prefix
    )

    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    row = saved(ctx)
    assert row.state == :manual_required

    assert {:error, :confirmation_changed} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               Ecto.UUID.generate(),
               row.google_subject,
               :google_access_removed
             )

    assert {:error, :confirmation_changed} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               row.request_id,
               "another-subject",
               :google_access_removed
             )

    assert {:error, :invalid_confirmation} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               row.request_id,
               row.google_subject,
               :assume_removed
             )

    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
    previous = row
    row = saved(ctx)
    refute row.request_id == previous.request_id

    assert {:error, :confirmation_changed} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               previous.request_id,
               previous.google_subject,
               :google_access_removed
             )

    assert {:ok, :operator_confirmed} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               row.request_id,
               row.google_subject,
               :google_access_removed
             )

    assert saved(ctx).outcome == :operator_confirmed
    assert host_binding(ctx).state == :disconnected
    assert {:ok, _} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
    fresh = host_binding(ctx)

    assert {:ok, :already_confirmed} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               row.request_id,
               row.google_subject,
               :google_access_removed
             )

    assert host_binding(ctx) == fresh
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)

    assert {:error, :confirmation_changed} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               row.request_id,
               row.google_subject,
               :google_access_removed
             )
  end

  test "operator confirmation never overrides a recoverable pending revocation", ctx do
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.inbox.id)
    row = saved(ctx)

    assert {:error, :manual_confirmation_unavailable} =
             Revocations.confirm_manual(
               ctx.inbox.id,
               row.request_id,
               row.google_subject,
               :google_access_removed
             )

    assert saved(ctx) == row
  end
end
