defmodule EmailJanitor.SelfHostGrantsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias EmailJanitor.{Content, SelfHost}
  alias EmailJanitor.Google.OAuth

  alias EmailJanitor.SelfHost.{
    Binding,
    Config,
    Credentials,
    GoogleGrant,
    RefreshAttempt,
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
    prior = Application.get_env(:email_janitor, :self_host_config)

    {:ok, oauth} =
      OAuth.Config.new("synthetic-client", "secret", "http://127.0.0.1/auth/google/callback")

    config = %Config{
      owner_email: "owner@example.com",
      public_url: "http://127.0.0.1",
      google_oauth: %{oauth | http_options: [plug: {Req.Test, :grant_refresh}]},
      credential_key: Content.new(:crypto.strong_rand_bytes(32)),
      web_secret: Content.new(String.duplicate("s", 64))
    }

    Application.put_env(:email_janitor, :self_host_config, config)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:email_janitor, :self_host_config, prior),
        else: Application.delete_env(:email_janitor, :self_host_config)
    end)

    first = result("A")
    {:ok, owner} = SelfHost.authorize_owner(first)
    {:ok, box} = SelfHost.connect(owner, first, "Etc/UTC")
    %{owner: owner, box: box, config: config, scope: SelfHost.scope(), first: first}
  end

  defp result(refresh, seconds \\ 3600) do
    %OAuth.Result{
      subject: "owner-subject",
      email: "owner@example.com",
      token:
        Content.new(
          Jason.encode!(%{
            access_token: "PRIVATE_ACCESS_#{refresh}",
            refresh_token: "PRIVATE_REFRESH_#{refresh}",
            expires_at: System.system_time(:second) + seconds,
            token_type: "Bearer",
            scope: "https://www.googleapis.com/auth/gmail.modify"
          })
        )
    }
  end

  defp host_binding(ctx), do: Repo.get!(Binding, ctx.box.id, prefix: ctx.scope.prefix)

  defp grants(ctx),
    do:
      Repo.all(
        from(g in GoogleGrant,
          where: g.inbox_id == ^ctx.box.id,
          order_by: [asc: g.inserted_at, asc: g.fingerprint]
        ),
        prefix: ctx.scope.prefix
      )

  defp tokens(ctx),
    do:
      Enum.map(grants(ctx), fn row ->
        {:ok, token} = SelfHost.open("gmail-token", ctx.box.id, row.token_ciphertext)
        Jason.decode!(Content.read(token))["refresh_token"]
      end)

  defp retire(ctx, expected, response \\ :ok) do
    assert {:ok, outcome} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, token ->
                 refute Repo.in_transaction?()

                 assert Jason.decode!(Content.read(token))["refresh_token"] ==
                          "PRIVATE_REFRESH_#{expected}"

                 response
               end
             )

    outcome
  end

  test "active reconsent retains each distinct grant, dedupes repeats and retires all before relink",
       ctx do
    Repo.update!(Ecto.Changeset.change(host_binding(ctx), state: :active),
      prefix: ctx.scope.prefix
    )

    assert {:ok, _} = SelfHost.connect(ctx.owner, result("B"), "Etc/UTC")
    assert {:ok, _} = SelfHost.connect(ctx.owner, result("B"), "Etc/UTC")
    assert {:ok, _} = SelfHost.connect(ctx.owner, result("C"), "Etc/UTC")
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B PRIVATE_REFRESH_C)
    assert host_binding(ctx).state == :active
    refute inspect(grants(ctx)) =~ "PRIVATE_"
    for row <- grants(ctx), do: refute(row.token_ciphertext =~ "PRIVATE_REFRESH")
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :retirement_continues
    assert host_binding(ctx).state == :revoking
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("D"), "Etc/UTC")
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_B PRIVATE_REFRESH_C PRIVATE_REFRESH_D)
    assert retire(ctx, "B") == :retirement_continues
    assert retire(ctx, "C", {:error, :refresh_token_invalid}) == :retirement_continues
    assert retire(ctx, "D") == :revoked
    assert grants(ctx) == []
    assert host_binding(ctx).state == :disconnected
    assert Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix).token_ciphertext == nil
    assert {:ok, _} = SelfHost.connect(ctx.owner, result("E"), "Etc/UTC")
  end

  test "a callback arriving while an old revoker owns wire is captured without activation", ctx do
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    observer = self()

    task =
      Task.async(fn ->
        Revocations.tick(ctx.config.google_oauth,
          revoke: fn _, _ ->
            send(observer, {:wire, self()})

            receive do
              :finish -> :ok
            end
          end
        )
      end)

    assert_receive {:wire, worker}, 5000
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("B"), "Etc/UTC")
    assert host_binding(ctx).token_ciphertext == nil
    send(worker, :finish)
    assert {:ok, :retirement_continues} = Task.await(task, 5000)
    assert tokens(ctx) == ["PRIVATE_REFRESH_B"]
    assert retire(ctx, "B") == :revoked
  end

  test "a repeated refresh ID captured after wire admission survives that older exact snapshot",
       ctx do
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    observer = self()

    task =
      Task.async(fn ->
        Revocations.tick(ctx.config.google_oauth,
          revoke: fn _, _ ->
            send(observer, {:wire, self()})

            receive do
              :finish -> :ok
            end
          end
        )
      end)

    assert_receive {:wire, worker}, 5000
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("A"), "Etc/UTC")
    send(worker, :finish)
    assert {:ok, :retirement_continues} = Task.await(task, 5000)
    assert tokens(ctx) == ["PRIVATE_REFRESH_A"]
    assert retire(ctx, "A", {:error, :refresh_token_invalid}) == :credential_unusable
    assert grants(ctx) == []
  end

  test "rejected timezone and short-lived credentials cannot discard an accepted offline capability",
       ctx do
    assert {:error, :invalid_connection} =
             SelfHost.connect(ctx.owner, result("B"), "bogus timezone")

    assert {:error, :invalid_connection} = SelfHost.connect(ctx.owner, result("C", -1), nil)
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B PRIVATE_REFRESH_C)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :retirement_continues
    assert retire(ctx, "B") == :retirement_continues
    assert retire(ctx, "C") == :revoked
  end

  test "SDK refresh rotation preserves both capabilities and retires nothing while newer consent is active",
       ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)

    Req.Test.stub(:grant_refresh, fn conn ->
      Req.Test.json(conn, %{
        access_token: "rotated-access",
        refresh_token: "PRIVATE_REFRESH_B",
        expires_in: 3600,
        token_type: "Bearer"
      })
    end)

    assert {:ok, access} = Credentials.token({ctx.box.id, before.epoch})
    assert Content.read(access) == "rotated-access"
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B)
    assert Repo.all(RefreshAttempt, prefix: ctx.scope.prefix) == []

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("active grant cannot be retired") end
             )

    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :retirement_continues
    assert retire(ctx, "B") == :revoked
  end

  test "disconnect cannot retire or release the subject before an actual SDK rotation reply is captured",
       ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)
    observer = self()

    Req.Test.stub(:grant_refresh, fn conn ->
      send(observer, {:refresh_wire, self()})

      receive do
        :finish -> :ok
      end

      Req.Test.json(conn, %{
        access_token: "rotated-access",
        refresh_token: "PRIVATE_REFRESH_B",
        expires_in: 3600,
        token_type: "Bearer"
      })
    end)

    task = Task.async(fn -> Credentials.token({ctx.box.id, before.epoch}) end)
    assert_receive {:refresh_wire, wire}, 5000
    assert Repo.aggregate(RefreshAttempt, :count, prefix: ctx.scope.prefix) == 1
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("wire still live") end
             )

    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("C"), "Etc/UTC")
    send(wire, :finish)
    assert {:error, :google_credentials_unavailable} = Task.await(task, 5000)
    assert Repo.all(RefreshAttempt, prefix: ctx.scope.prefix) == []
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_C PRIVATE_REFRESH_B)
    assert retire(ctx, "A") == :retirement_continues
    assert retire(ctx, "C") == :retirement_continues
    assert retire(ctx, "B") == :revoked
  end

  test "a late SDK rotation loses publication CAS but its capability remains behind the newer consent",
       ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)
    observer = self()

    Req.Test.stub(:grant_refresh, fn conn ->
      send(observer, {:refresh_wire, self()})

      receive do
        :finish -> :ok
      end

      Req.Test.json(conn, %{
        access_token: "stale-access",
        refresh_token: "PRIVATE_REFRESH_B",
        expires_in: 3600,
        token_type: "Bearer"
      })
    end)

    task = Task.async(fn -> Credentials.token({ctx.box.id, before.epoch}) end)
    assert_receive {:refresh_wire, wire}, 5000
    assert {:ok, _} = SelfHost.connect(ctx.owner, result("C"), "Etc/UTC")
    send(wire, :finish)
    assert {:ok, current} = Task.await(task, 5000)
    assert Content.read(current) == "PRIVATE_ACCESS_C"
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_C PRIVATE_REFRESH_B)

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("newer active grant") end
             )
  end

  test "invalid current refresh proof does not erase an older still-owned capability", ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("B", 30), "Etc/UTC")
    before = host_binding(ctx)

    Req.Test.stub(:grant_refresh, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "invalid_grant"})
    end)

    assert {:error, :reauthorization_required} = Credentials.token({ctx.box.id, before.epoch})
    assert tokens(ctx) == ["PRIVATE_REFRESH_A"]
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert host_binding(ctx).state == :revoking
    assert retire(ctx, "A") == :revoked
  end

  test "a short-lived SDK rotation is captured even when it cannot be published", ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)

    Req.Test.stub(:grant_refresh, fn conn ->
      Req.Test.json(conn, %{
        access_token: "short-access",
        refresh_token: "PRIVATE_REFRESH_B",
        expires_in: 60,
        token_type: "Bearer"
      })
    end)

    assert {:error, :google_credentials_unavailable} =
             Credentials.token({ctx.box.id, before.epoch})

    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B)
    assert Repo.all(RefreshAttempt, prefix: ctx.scope.prefix) == []
  end

  test "confirmed owner death physically quarantines lost SDK replies; invalid old tokens cannot hide uncertainty",
       ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)
    observer = self()

    Req.Test.stub(:grant_refresh, fn _conn ->
      send(observer, {:stalled_refresh, self()})

      receive do
        :never -> flunk("stalled fixture unexpectedly resumed")
      end
    end)

    caller = Task.async(fn -> Credentials.token({ctx.box.id, before.epoch}) end)
    assert_receive {:stalled_refresh, wire}, 5000
    monitor = Process.monitor(wire)
    Process.unlink(caller.pid)
    Process.exit(caller.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^wire, _}, 5000
    [attempt] = Repo.all(RefreshAttempt, prefix: ctx.scope.prefix)
    assert EmailJanitor.Owner.proof(attempt) == :dead
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    started = System.monotonic_time(:millisecond)

    assert {:ok, :refresh_quarantined} =
             Revocations.tick(ctx.config.google_oauth,
               now: DateTime.add(DateTime.utc_now(), 86_400),
               revoke: fn _, _ -> flunk("must wait for last possible refresh") end
             )

    assert System.monotonic_time(:millisecond) - started >= 30_000
    assert retire(ctx, "A", {:error, :refresh_token_invalid}) == :manual_confirmation_required
    assert host_binding(ctx).state == :revocation_required
    assert grants(ctx) == []
    old = Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix)
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("B"), "Etc/UTC")
    fresh = Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix)
    refute old.request_id == fresh.request_id

    assert {:error, :confirmation_changed} =
             Revocations.confirm_manual(
               ctx.box.id,
               old.request_id,
               old.google_subject,
               :google_access_removed
             )

    assert {:ok, :operator_confirmed} =
             Revocations.confirm_manual(
               ctx.box.id,
               fresh.request_id,
               fresh.google_subject,
               :google_access_removed
             )

    assert grants(ctx) == []
    assert Repo.all(RefreshAttempt, prefix: ctx.scope.prefix) == []
  end

  test "a positive project revocation resolves already-quarantined response uncertainty", ctx do
    dead = Task.async(fn -> EmailJanitor.Owner.capture() end) |> Task.await()

    row =
      struct!(
        RefreshAttempt,
        Map.merge(dead, %{
          id: Ecto.UUID.generate(),
          inbox_id: ctx.box.id,
          source_version: 1,
          state: :quarantined
        })
      )

    Repo.insert!(row, prefix: ctx.scope.prefix)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :revoked
    assert host_binding(ctx).state == :disconnected
    assert Repo.all(RefreshAttempt, prefix: ctx.scope.prefix) == []
  end

  test "legacy in-flight rows hydrate without overwriting a newer captured snapshot", ctx do
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    Repo.delete_all(GoogleGrant, prefix: ctx.scope.prefix)
    old = Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix)
    Repo.update!(Ecto.Changeset.change(old, grant_fingerprint: nil), prefix: ctx.scope.prefix)
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("A"), "Etc/UTC")
    assert retire(ctx, "A") == :retirement_continues
    assert tokens(ctx) == ["PRIVATE_REFRESH_A"]
    assert retire(ctx, "A", {:error, :refresh_token_invalid}) == :credential_unusable
    assert grants(ctx) == []
  end

  test "fingerprints and retirement are scoped to the immutable Google identity", ctx do
    other = %{result("A") | subject: "work-subject", email: "work@example.com"}
    assert {:ok, box} = SelfHost.connect(ctx.owner, other, "Etc/UTC")
    [first] = grants(ctx)

    [second] =
      Repo.all(from(g in GoogleGrant, where: g.inbox_id == ^box.id), prefix: ctx.scope.prefix)

    refute first.fingerprint == second.fingerprint
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :revoked

    assert Repo.get_by!(GoogleGrant, [inbox_id: box.id], prefix: ctx.scope.prefix).token_ciphertext ==
             second.token_ciphertext
  end

  test "a publication SQL failure cannot roll back independently captured consent", ctx do
    Repo.update!(Ecto.Changeset.change(host_binding(ctx), state: :active),
      prefix: ctx.scope.prefix
    )

    before = host_binding(ctx)

    Repo.query!(
      ~s|ALTER TABLE "ej_selfhost".self_host_bindings ADD CONSTRAINT consent_publish_failure CHECK (token_version <= #{before.token_version}) NOT VALID|,
      [],
      log: false
    )

    assert {:error, _} = SelfHost.connect(ctx.owner, result("B"), "Etc/UTC")
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B)
    assert host_binding(ctx).token_ciphertext == before.token_ciphertext
    assert host_binding(ctx).state == :active

    Repo.query!(
      ~s|ALTER TABLE "ej_selfhost".self_host_bindings DROP CONSTRAINT consent_publish_failure|,
      [],
      log: false
    )

    assert {:ok, _} = SelfHost.connect(ctx.owner, result("C"), "Etc/UTC")
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B PRIVATE_REFRESH_C)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :retirement_continues
    assert retire(ctx, "B") == :retirement_continues
    assert retire(ctx, "C") == :revoked
  end

  test "a refresh publication SQL failure cannot roll back independent capability capture", ctx do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)

    Repo.query!(
      ~s|ALTER TABLE "ej_selfhost".self_host_bindings ADD CONSTRAINT refresh_publish_failure CHECK (token_version <= #{before.token_version}) NOT VALID|,
      [],
      log: false
    )

    Req.Test.stub(:grant_refresh, fn conn ->
      Req.Test.json(conn, %{
        access_token: "rotated-access",
        refresh_token: "PRIVATE_REFRESH_B",
        expires_in: 3600,
        token_type: "Bearer"
      })
    end)

    assert {:error, :google_credentials_unavailable} =
             Credentials.token({ctx.box.id, before.epoch})

    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B)
    assert Repo.all(RefreshAttempt, prefix: ctx.scope.prefix) == []
    assert host_binding(ctx).token_ciphertext == before.token_ciphertext

    Repo.query!(
      ~s|ALTER TABLE "ej_selfhost".self_host_bindings DROP CONSTRAINT refresh_publish_failure|,
      [],
      log: false
    )
  end

  test "valid SDK credentials with declined Gmail scope are retained for retirement, never activated",
       ctx do
    basic = %{
      result("B")
      | token:
          Content.new(
            Jason.encode!(
              Map.put(
                Jason.decode!(Content.read(result("B").token)),
                "scope",
                "openid email"
              )
            )
          )
    }

    assert {:error, :invalid_connection} = SelfHost.connect(ctx.owner, basic, "Etc/UTC")
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_A PRIVATE_REFRESH_B)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "A") == :retirement_continues
    assert retire(ctx, "B") == :revoked
  end

  test "a rejected legacy mailbox association retires the captured grant without adopting historical authority",
       ctx do
    subject = "legacy-subject"
    id = "google-" <> Base.encode16(:crypto.hash(:sha256, subject), case: :lower)

    Repo.insert!(
      %EmailJanitor.Store.Mailbox{id: id, address: "former@example.com", instruction_version: 1},
      prefix: ctx.scope.prefix
    )

    profile = %{result("B") | subject: subject, email: "new@example.com"}
    assert {:error, :invalid_connection} = SelfHost.connect(ctx.owner, profile, "Etc/UTC")
    assert Repo.get(Binding, id, prefix: ctx.scope.prefix) == nil

    assert {:ok, :revoked} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, token ->
                 assert Jason.decode!(Content.read(token))["refresh_token"] == "PRIVATE_REFRESH_B"
                 :ok
               end
             )

    assert Repo.get(Binding, id, prefix: ctx.scope.prefix) == nil

    assert Repo.get!(EmailJanitor.Store.Mailbox, id, prefix: ctx.scope.prefix).address ==
             "former@example.com"

    assert Repo.all(from(g in GoogleGrant, where: g.inbox_id == ^id), prefix: ctx.scope.prefix) ==
             []
  end

  defp overlapping_refreshes(ctx) do
    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)
    observer = self()

    Req.Test.stub(:grant_refresh, fn conn ->
      send(observer, {:overlapping_refresh, self()})

      receive do
        :invalid ->
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "invalid_grant"})

        :rotate ->
          Req.Test.json(conn, %{
            access_token: "late-rotation",
            refresh_token: "PRIVATE_REFRESH_B",
            expires_in: 3600,
            token_type: "Bearer"
          })
      end
    end)

    late = Task.async(fn -> Credentials.token({ctx.box.id, before.epoch}) end)
    assert_receive {:overlapping_refresh, late_wire}, 5000
    invalid = Task.async(fn -> Credentials.token({ctx.box.id, before.epoch}) end)
    assert_receive {:overlapping_refresh, invalid_wire}, 5000
    send(invalid_wire, :invalid)
    assert {:error, :reauthorization_required} = Task.await(invalid, 5000)
    assert tokens(ctx) == []
    assert host_binding(ctx).state == :reauthorization_required
    {late, late_wire}
  end

  test "disconnect after invalid current proof remains fenced behind another live SDK reply",
       ctx do
    {late, wire} = overlapping_refreshes(ctx)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert host_binding(ctx).state == :revocation_required
    old = Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix)
    assert old.state == :manual_required

    assert {:error, :refresh_pending} =
             Revocations.confirm_manual(
               ctx.box.id,
               old.request_id,
               old.google_subject,
               :google_access_removed
             )

    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("C"), "Etc/UTC")
    send(wire, :rotate)
    assert {:error, :google_credentials_unavailable} = Task.await(late, 5000)
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_C PRIVATE_REFRESH_B)
    fresh = Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix)
    assert fresh.state == :manual_required
    refute fresh.request_id == old.request_id
    assert host_binding(ctx).state == :revocation_required
  end

  test "invalid current proof cannot erase already quarantined rotation uncertainty on disconnect",
       ctx do
    dead = Task.async(fn -> EmailJanitor.Owner.capture() end) |> Task.await()

    Repo.insert!(
      struct!(
        RefreshAttempt,
        Map.merge(dead, %{
          id: Ecto.UUID.generate(),
          inbox_id: ctx.box.id,
          source_version: host_binding(ctx).token_version,
          state: :quarantined
        })
      ),
      prefix: ctx.scope.prefix
    )

    {:ok, _} = SelfHost.connect(ctx.owner, result("A", 30), "Etc/UTC")
    before = host_binding(ctx)

    Req.Test.stub(:grant_refresh, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "invalid_grant"})
    end)

    assert {:error, :reauthorization_required} = Credentials.token({ctx.box.id, before.epoch})
    assert tokens(ctx) == []
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert host_binding(ctx).state == :revocation_required
    row = Repo.get!(Revocation, ctx.box.id, prefix: ctx.scope.prefix)
    assert row.state == :manual_required
    assert {:error, :revocation_pending} = SelfHost.connect(ctx.owner, result("B"), "Etc/UTC")
  end

  test "a late accepted SDK reply behind reauthorization stays dormant until explicit retirement",
       ctx do
    {late, wire} = overlapping_refreshes(ctx)
    failed = host_binding(ctx)
    send(wire, :rotate)
    assert {:error, :google_credentials_unavailable} = Task.await(late, 5000)
    assert host_binding(ctx).state == :reauthorization_required
    assert tokens(ctx) == ["PRIVATE_REFRESH_B"]
    assert Repo.get(Revocation, ctx.box.id, prefix: ctx.scope.prefix) == nil

    assert {:ok, :idle} =
             Revocations.tick(ctx.config.google_oauth,
               revoke: fn _, _ -> flunk("reauthorization is not a retirement request") end
             )

    assert {:ok, _} = SelfHost.connect(ctx.owner, result("C"), "Etc/UTC")
    resumed = host_binding(ctx)
    assert resumed.epoch == failed.epoch
    assert tokens(ctx) == ~w(PRIVATE_REFRESH_B PRIVATE_REFRESH_C)
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert retire(ctx, "B") == :retirement_continues
    assert retire(ctx, "C") == :revoked
  end
end
