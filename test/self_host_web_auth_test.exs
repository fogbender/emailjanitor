defmodule EmailJanitor.SelfHostWeb.AuthTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, TestRepo}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHostWeb.{Auth, TestHost, TestOAuth}
  alias Auth.{Attempt, Session}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = EmailJanitor.Store.Scope.new(TestRepo, "ej_test_a")
    keys = [:self_host_adapter, :self_host_oauth, :browser_test_scope, :browser_test_observer]
    old = Map.new(keys, &{&1, Application.fetch_env(:email_janitor, &1)})
    Application.put_env(:email_janitor, :self_host_adapter, TestHost)
    Application.put_env(:email_janitor, :browser_test_scope, scope)
    Application.put_env(:email_janitor, :browser_test_observer, self())
    Application.put_env(:email_janitor, :self_host_oauth, {TestOAuth, identity()})

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        case value do
          {:ok, value} -> Application.put_env(:email_janitor, key, value)
          :error -> Application.delete_env(:email_janitor, key)
        end
      end)
    end)

    %{scope: scope, now: DateTime.utc_now()}
  end

  defp identity,
    do: %OAuth.Result{
      subject: "owner-subject",
      email: "owner@acme.com",
      token: Content.new("synthetic")
    }

  defp params, do: %{"code" => "valid", "state" => String.duplicate("r", 32)}

  test "verified owner sign-in issues only an opaque revocable browser session", t do
    assert {:ok, flow} = Auth.begin(:sign_in, nil, "America/Los_Angeles", t.now)
    assert {:ok, token} = Auth.complete(flow.browser_token, params(), nil, t.now)
    assert {:ok, "owner-subject"} = Auth.fetch(Content.read(token), t.now)
    [row] = TestRepo.all(Session, prefix: t.scope.prefix)
    refute row.id == Content.read(token)
    assert byte_size(row.id) == 32
    assert TestRepo.all(Attempt, prefix: t.scope.prefix) == []
    assert :ok = Auth.revoke(Content.read(token))
    assert {:error, :unauthorized} = Auth.fetch(Content.read(token), t.now)
  end

  test "connect requires a current owner session and cannot be bootstrapped anonymously", t do
    assert {:error, :google_unavailable} = Auth.begin(:connect, nil, "Etc/UTC", t.now)
    assert TestRepo.all(Attempt, prefix: t.scope.prefix) == []
    refute_receive {:connected, _, _, _}
  end

  test "encrypted attempts bind both the initiating session and browser and are single use", t do
    {:ok, session} = Auth.issue("owner-subject", nil, t.now)
    raw_session = Content.read(session)
    {:ok, flow} = Auth.begin(:connect, raw_session, "America/New_York", t.now)
    [attempt] = TestRepo.all(Attempt, prefix: t.scope.prefix)
    refute attempt.ciphertext =~ String.duplicate("v", 43)
    refute attempt.browser_hash == flow.browser_token

    assert {:error, :google_unavailable} =
             Auth.complete(String.duplicate("x", 43), params(), raw_session, t.now)

    assert {:error, :google_unavailable} = Auth.complete(flow.browser_token, params(), nil, t.now)
    assert {:ok, replacement} = Auth.complete(flow.browser_token, params(), raw_session, t.now)
    assert_receive {:connected, "owner-subject", "owner-subject", "America/New_York"}
    assert {:error, :unauthorized} = Auth.fetch(raw_session, t.now)
    assert {:ok, "owner-subject"} = Auth.fetch(Content.read(replacement), t.now)

    assert {:error, :google_unavailable} =
             Auth.complete(flow.browser_token, params(), Content.read(replacement), t.now)

    refute_receive {:connected, _, _, _}
  end

  test "a signed-in owner can connect a distinct verified Google account without becoming that account",
       t do
    result = %{identity() | subject: "other-inbox-subject", email: "other@example.org"}
    Application.put_env(:email_janitor, :self_host_oauth, {TestOAuth, result})
    {:ok, session} = Auth.issue("owner-subject", nil, t.now)
    {:ok, flow} = Auth.begin(:connect, Content.read(session), "Etc/UTC", t.now)
    assert {:ok, next} = Auth.complete(flow.browser_token, params(), Content.read(session), t.now)
    assert_receive {:connected, "owner-subject", "other-inbox-subject", "Etc/UTC"}
    assert {:ok, "owner-subject"} = Auth.fetch(Content.read(next), t.now)
  end

  test "unrecognized verified identities cannot sign in as the owner", t do
    Application.put_env(
      :email_janitor,
      :self_host_oauth,
      {TestOAuth, %{identity() | subject: "attacker", email: "attacker@example.org"}}
    )

    {:ok, flow} = Auth.begin(:sign_in, nil, "Etc/UTC", t.now)
    assert {:error, :google_unavailable} = Auth.complete(flow.browser_token, params(), nil, t.now)
    assert TestRepo.all(Session, prefix: t.scope.prefix) == []
  end

  test "revoked or changed initiating sessions cannot complete an old connection attempt", t do
    {:ok, first} = Auth.issue("owner-subject", nil, t.now)
    {:ok, flow} = Auth.begin(:connect, Content.read(first), "Etc/UTC", t.now)
    {:ok, second} = Auth.issue("owner-subject", Content.read(first), t.now)

    assert {:error, :google_unavailable} =
             Auth.complete(flow.browser_token, params(), Content.read(second), t.now)

    assert {:error, :google_unavailable} =
             Auth.complete(flow.browser_token, params(), Content.read(first), t.now)

    refute_receive {:connected, _, _, _}
  end

  test "expiry is enforced by the server and maintenance purges only expired metadata", t do
    {:ok, flow} = Auth.begin(:sign_in, nil, "Etc/UTC", t.now)

    assert {:error, :google_unavailable} =
             Auth.complete(flow.browser_token, params(), nil, DateTime.add(t.now, 601))

    {:ok, session} = Auth.issue("owner-subject", nil, t.now)

    assert {:error, :unauthorized} =
             Auth.fetch(Content.read(session), DateTime.add(t.now, 2_592_001))

    assert :ok = Auth.purge(DateTime.add(t.now, 601))
    assert TestRepo.aggregate(Attempt, :count, prefix: t.scope.prefix) == 0
    assert TestRepo.aggregate(Session, :count, prefix: t.scope.prefix) == 1
  end

  test "failed callbacks do not log or persist callback input or plaintext credentials", t do
    {:ok, flow} = Auth.begin(:sign_in, nil, "Etc/UTC", t.now)

    log =
      capture_log(fn ->
        assert {:error, :google_unavailable} =
                 Auth.complete(
                   flow.browser_token,
                   %{
                     "code" => "PRIVATE_CALLBACK_CODE",
                     "state" => "wrong",
                     "message" => "PRIVATE_REQUEST_BODY"
                   },
                   nil,
                   t.now
                 )
      end)

    refute log =~ "PRIVATE_CALLBACK_CODE"
    refute log =~ "PRIVATE_REQUEST_BODY"
    assert TestRepo.all(Attempt, prefix: t.scope.prefix) == []
    assert TestRepo.all(Session, prefix: t.scope.prefix) == []
  end

  test "anonymous attempts have a durable bounded cap while the owner can still connect", t do
    for _ <- 1..20, do: assert({:ok, _} = Auth.begin(:sign_in, nil, "Etc/UTC", t.now))
    assert {:error, :too_many_attempts} = Auth.begin(:sign_in, nil, "Etc/UTC", t.now)
    assert TestRepo.aggregate(Attempt, :count, prefix: t.scope.prefix) == 20
    {:ok, owner} = Auth.issue("owner-subject", nil, t.now)
    assert {:ok, _} = Auth.begin(:connect, Content.read(owner), "Etc/UTC", t.now)
    assert {:ok, _} = Auth.begin(:sign_in, nil, "Etc/UTC", DateTime.add(t.now, 601))
    assert TestRepo.aggregate(Attempt, :count, prefix: t.scope.prefix) == 1
  end
end
