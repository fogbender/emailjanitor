defmodule EmailJanitor.GoogleOAuthTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias EmailJanitor.Content
  alias EmailJanitor.Google.OAuth
  alias OAuth.{Config, Result, Session}

  @gmail "https://www.googleapis.com/auth/gmail.modify"
  @client "fixture-client.apps.googleusercontent.com"
  @secret "CLIENT_SECRET_SENTINEL"
  @redirect "https://janitor.example/auth/google/callback"

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    private = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    public = %{
      "kty" => "RSA",
      "kid" => "fixture-key",
      "alg" => "RS256",
      "use" => "sig",
      "n" => Base.url_encode64(:binary.encode_unsigned(elem(key, 2)), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(elem(key, 3)), padding: false)
    }

    {:ok, private: private, public: public}
  end

  setup do
    {:ok, config} = Config.new(@client, @secret, @redirect)
    {:ok, config: %{config | http_options: [plug: {Req.Test, __MODULE__}]}}
  end

  test "config only accepts trusted HTTPS or loopback redirects and redacts its secret" do
    assert {:ok, config} = Config.new(@client, @secret, @redirect)
    refute inspect(config) =~ @secret
    assert {:ok, _} = Config.new(@client, @secret, "http://127.0.0.1:4455/callback")

    for redirect <- [
          "http://public.example/callback",
          "https://user:password@host.example/callback",
          "https://host.example/callback#fragment",
          "file:///tmp/callback",
          nil
        ] do
      assert {:error, :invalid_oauth_config} = Config.new(@client, @secret, redirect)
    end

    assert {:error, :invalid_oauth_config} = Config.new(@client, "secret\r\n", @redirect)
  end

  test "sign-in has minimal scopes and fresh state, nonce and S256 PKCE without HTTP", %{
    config: config
  } do
    Req.Test.stub(__MODULE__, fn _ -> flunk("authorization URL must not contact a provider") end)

    assert {:ok, %{url: first_url, session_params: %Session{} = first}} =
             OAuth.authorize_url(config, :sign_in)

    assert {:ok, %{session_params: second}} = OAuth.authorize_url(config, :sign_in)
    uri = URI.parse(first_url)
    params = URI.decode_query(uri.query)

    assert uri.scheme == "https" and uri.host == "accounts.google.com" and
             uri.path == "/o/oauth2/v2/auth"

    assert MapSet.new(String.split(params["scope"])) == MapSet.new(["openid", "email"])
    assert params["response_type"] == "code"
    assert params["redirect_uri"] == @redirect
    assert params["client_id"] == @client
    assert params["state"] == first.state and params["nonce"] == first.nonce
    assert params["code_challenge_method"] == "S256"

    assert params["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, first.code_verifier), padding: false)

    refute Map.has_key?(params, "code_verifier")
    assert byte_size(first.code_verifier) == 128
    refute first.state == second.state
    refute first.nonce == second.nonce
    refute first.code_verifier == second.code_verifier
    refute first_url =~ @secret
    assert {:error, :invalid_oauth_config} = OAuth.authorize_url(config, :arbitrary_scope)
  end

  test "connecting requests exactly Gmail.modify plus identity and offline consent", %{
    config: config
  } do
    assert {:ok, %{url: url, session_params: %{mode: :connect}}} =
             OAuth.authorize_url(config, :connect)

    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert MapSet.new(String.split(params["scope"])) == MapSet.new(["openid", "email", @gmail])
    assert params["access_type"] == "offline"
    assert params["prompt"] == "consent"
  end

  test "session serialization is explicit and fixed-key, and ordinary inspect/JSON redact it", %{
    config: config
  } do
    session = session(config)
    content = OAuth.dump_session(session)
    assert %Content{} = content
    assert {:ok, ^session} = OAuth.load_session(content)
    refute inspect(session) =~ session.code_verifier
    refute inspect(content) =~ session.nonce
    assert Jason.encode!(session) == ~s("[REDACTED]")
    assert Jason.encode!(content) == ~s("[REDACTED]")
    plain = Jason.decode!(Content.read(content))

    for malformed <- [
          Map.delete(plain, "nonce"),
          Map.put(plain, "extra", "data"),
          Map.put(plain, "state", false),
          Map.put(plain, "mode", "admin"),
          Map.put(plain, "code_challenge", "wrong"),
          Map.put(plain, "code_verifier", "short")
        ] do
      assert {:error, :invalid_session} =
               OAuth.load_session(Content.new(Jason.encode!(malformed)))
    end

    assert {:error, :invalid_session} = OAuth.load_session(Content.new("[]"))

    assert {:error, :invalid_session} =
             OAuth.load_session(Content.new(String.duplicate("x", 4097)))
  end

  test "callback exchanges code and PKCE through Assent and verifies an actual RS256 ID token",
       context do
    session = session(context.config)
    token = token(context, session)

    fixture(context, token, fn form ->
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "AUTH_CODE_SENTINEL"
      assert form["code_verifier"] == session.code_verifier
      assert form["client_secret"] == @secret
      assert form["client_id"] == @client
      assert form["redirect_uri"] == @redirect
      refute Map.has_key?(form, "token_url")
    end)

    assert {:ok,
            %Result{
              subject: "google-subject-123",
              email: "owner@acme.com",
              token: %Content{} = secret
            } = result} = OAuth.callback(context.config, session, callback_params(session))

    stored = Jason.decode!(Content.read(secret))
    assert stored["access_token"] == "ACCESS_TOKEN_SENTINEL"
    assert stored["refresh_token"] == "REFRESH_TOKEN_SENTINEL"
    assert stored["expires_at"] > System.system_time(:second)
    refute Map.has_key?(stored, "id_token")
    refute Map.has_key?(stored, "provider_extra")
    refute inspect(result) =~ "TOKEN_SENTINEL"
    refute Jason.encode!(result) =~ "TOKEN_SENTINEL"
  end

  test "bad state, missing nonce or verifier fail before any HTTP", %{config: config} do
    owner = self()

    Req.Test.stub(__MODULE__, fn _ ->
      send(owner, :unexpected_invalid_attempt_http)
      raise "invalid attempt must not contact Google"
    end)

    session = session(config)

    assert {:error, :authorization_failed} =
             OAuth.callback(config, session, %{"state" => "wrong", "code" => "code"})

    for malformed <- [
          %{session | nonce: nil},
          %{session | code_verifier: nil},
          %{session | code_challenge_method: "plain"}
        ] do
      assert {:error, :authorization_failed} =
               OAuth.callback(config, malformed, callback_params(session))
    end

    assert {:error, :authorization_failed} =
             OAuth.callback(
               config,
               session,
               Map.put(callback_params(session), "error", "access_denied")
             )

    refute_received :unexpected_invalid_attempt_http
  end

  test "issuer, audience, authorized party, nonce, subject, verified email and dates are enforced",
       context do
    session = session(context.config)
    now = System.system_time(:second)

    for change <- [
          %{"iss" => "https://attacker.example"},
          %{"aud" => "other-client"},
          %{"aud" => [@client, "other-client"]},
          %{"azp" => "other-client"},
          %{"nonce" => "other-nonce"},
          %{"nonce" => nil},
          %{"sub" => ""},
          %{"sub" => nil},
          %{"sub" => 123},
          %{"sub" => "has space"},
          %{"email_verified" => false},
          %{"email_verified" => "true"},
          %{"email" => "not-an-email"},
          %{"exp" => now - 1},
          %{"exp" => "9999999999"},
          %{"exp" => nil},
          %{"iat" => now - 700},
          %{"iat" => now + 60},
          %{"iat" => "bad"}
        ] do
      fixture(context, token(context, session, change))

      assert {:error, :authorization_failed} =
               OAuth.callback(context.config, session, callback_params(session))
    end
  end

  test "unsigned, HS256, wrong signing key, unknown kid and missing required claims are rejected",
       context do
    session = session(context.config)
    claims = claims(session)
    {:ok, hs256} = Assent.JWTAdapter.sign(claims, "HS256", @secret, json_library: Jason)

    unsigned =
      Base.url_encode64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> "."

    other_key = :public_key.generate_key({:rsa, 2048, 65_537})
    other_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, other_key)])

    {:ok, wrong_key} =
      Assent.JWTAdapter.sign(claims, "RS256", other_pem,
        json_library: Jason,
        private_key_id: "fixture-key"
      )

    {:ok, unknown_kid} =
      Assent.JWTAdapter.sign(claims, "RS256", context.private,
        json_library: Jason,
        private_key_id: "unknown"
      )

    missing_exp = sign(context, Map.delete(claims, "exp"))

    for id_token <- [hs256, unsigned, wrong_key, unknown_kid, missing_exp, "not-a-jwt"] do
      fixture(context, Map.put(token(context, session), "id_token", id_token))

      assert {:error, :authorization_failed} =
               OAuth.callback(context.config, session, callback_params(session))
    end
  end

  test "connect requires Gmail scope and durable refresh consent while sign-in only needs identity",
       context do
    connect = session(context.config, :connect)

    for raw <- [
          Map.put(token(context, connect), "scope", "openid email"),
          Map.delete(token(context, connect), "refresh_token")
        ] do
      fixture(context, raw)

      assert {:error, :authorization_failed} =
               OAuth.callback(context.config, connect, callback_params(connect))
    end

    signin = session(context.config)

    fixture(
      context,
      token(context, signin) |> Map.put("scope", "openid email") |> Map.delete("refresh_token")
    )

    assert {:ok, %Result{}} = OAuth.callback(context.config, signin, callback_params(signin))
  end

  test "callback params cannot override endpoints or the trusted application", context do
    session = session(context.config)
    fixture(context, token(context, session))

    params =
      Map.merge(callback_params(session), %{
        "token_url" => "https://attacker.example",
        "client_id" => "evil",
        "client_secret" => "evil",
        "http_adapter" => "evil",
        "redirect_uri" => "https://attacker.example"
      })

    assert {:ok, %Result{}} = OAuth.callback(context.config, session, params)
  end

  test "failed token exchange is not retried and errors/logs contain no provider secrets",
       context do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :provider_request)
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "PROVIDER_SECRET_SENTINEL"})
    end)

    session = session(context.config)

    log =
      capture_log(fn ->
        assert {:error, :authorization_failed} =
                 OAuth.callback(context.config, session, callback_params(session))
      end)

    assert_received :provider_request
    refute_received :provider_request
    refute log =~ "SENTINEL"
  end

  test "redirect token responses are not followed", context do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:request, conn.host})

      conn
      |> Plug.Conn.put_resp_header("location", "https://attacker.example/steal")
      |> Plug.Conn.send_resp(307, "PROVIDER_SECRET_SENTINEL")
    end)

    session = session(context.config)

    assert {:error, :authorization_failed} =
             OAuth.callback(context.config, session, callback_params(session))

    assert_received {:request, "oauth2.googleapis.com"}
    refute_received {:request, _}
  end

  test "JWKS GET failures are not retried or logged", context do
    owner = self()
    session = session(context.config)
    raw = token(context, session)

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:provider_method, conn.method})

      if conn.method == "POST" do
        Req.Test.json(conn, raw)
      else
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "KEY_SERVER_SECRET_SENTINEL"})
      end
    end)

    log =
      capture_log(fn ->
        assert {:error, :authorization_failed} =
                 OAuth.callback(context.config, session, callback_params(session))
      end)

    assert_received {:provider_method, "POST"}
    assert_received {:provider_method, "GET"}
    refute_received {:provider_method, _}
    refute log =~ "SENTINEL"
  end

  test "refresh uses the SDK and preserves omitted refresh token/scope while dropping extra fields",
       context do
    fixture(
      context,
      %{
        "access_token" => "NEW_ACCESS_SENTINEL",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "id_token" => "unneeded",
        "provider_extra" => "discard"
      },
      fn form ->
        assert form["grant_type"] == "refresh_token"
        assert form["refresh_token"] == "REFRESH_TOKEN_SENTINEL"
        assert form["client_secret"] == @secret
        refute Map.has_key?(form, "access_token")
      end
    )

    assert {:ok, %Content{} = refreshed} = OAuth.refresh(context.config, old_token())
    raw = Jason.decode!(Content.read(refreshed))
    assert raw["access_token"] == "NEW_ACCESS_SENTINEL"
    assert raw["refresh_token"] == "REFRESH_TOKEN_SENTINEL"
    assert raw["scope"] == "openid email " <> @gmail
    assert raw["expires_at"] > System.system_time(:second)
    assert Enum.sort(Map.keys(raw)) == ~w(access_token expires_at refresh_token scope token_type)
    refute inspect(refreshed) =~ "SENTINEL"
  end

  test "refresh accepts rotation and rejects malformed responses and missing old refresh credentials",
       context do
    for raw <- [
          %{"access_token" => "", "expires_in" => 3600, "token_type" => "Bearer"},
          %{"access_token" => "token", "expires_in" => "3600", "token_type" => "Bearer"},
          %{"access_token" => "token", "expires_in" => 3600, "token_type" => "MAC"},
          %{"access_token" => "token\r\n", "expires_in" => 3600, "token_type" => "Bearer"}
        ] do
      fixture(context, raw)
      assert {:error, :refresh_failed} = OAuth.refresh(context.config, old_token())
    end

    fixture(context, %{
      "access_token" => "new-token",
      "expires_in" => 3600,
      "token_type" => "Bearer",
      "refresh_token" => "rotated-refresh"
    })

    assert {:ok, refreshed} = OAuth.refresh(context.config, old_token())
    assert Jason.decode!(Content.read(refreshed))["refresh_token"] == "rotated-refresh"
    owner = self()

    Req.Test.stub(__MODULE__, fn _ ->
      send(owner, :unexpected_invalid_refresh_http)
      raise "malformed stored token must not contact Google"
    end)

    assert {:error, :refresh_failed} = OAuth.refresh(context.config, Content.new("{}"))
    assert {:error, :refresh_failed} = OAuth.refresh(context.config, Content.new("not-json"))
    assert {:error, :refresh_failed} = OAuth.refresh(context.config, Content.new("[]"))
    refute_received :unexpected_invalid_refresh_http
  end

  test "refresh distinguishes expired grants from outages and never exposes provider errors",
       context do
    owner = self()

    for {status, code, expected} <- [
          {400, "invalid_grant", :reauthorization_required},
          {400, "invalid_client", :refresh_failed},
          {503, "invalid_grant", :refresh_failed},
          {429, "rate_limit", :refresh_failed}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, :refresh_request)
        assert conn.host == "oauth2.googleapis.com" and conn.request_path == "/token"

        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{
          "error" => code,
          "error_description" => "PRIVATE_REFRESH_ERROR_SENTINEL"
        })
      end)

      log =
        capture_log(fn ->
          assert {:error, ^expected} = OAuth.refresh(context.config, old_token())
        end)

      assert_received :refresh_request
      refute_received :refresh_request
      refute log =~ "SENTINEL"
    end

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, :refresh_failed} = OAuth.refresh(context.config, old_token())
  end

  defp fixture(context, raw, check_form \\ fn _ -> :ok end) do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.host, conn.request_path} do
        {"POST", "oauth2.googleapis.com", "/token"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          check_form.(URI.decode_query(body))
          Req.Test.json(conn, raw)

        {"GET", "www.googleapis.com", "/oauth2/v3/certs"} ->
          Req.Test.json(conn, %{"keys" => [context.public]})

        _ ->
          flunk("unexpected OAuth endpoint")
      end
    end)
  end

  defp session(config, mode \\ :sign_in) do
    {:ok, %{session_params: session}} = OAuth.authorize_url(config, mode)
    session
  end

  defp callback_params(session), do: %{"state" => session.state, "code" => "AUTH_CODE_SENTINEL"}

  defp claims(session),
    do: %{
      "iss" => "https://accounts.google.com",
      "aud" => @client,
      "sub" => "google-subject-123",
      "email" => "Owner@Acme.com",
      "email_verified" => true,
      "exp" => System.system_time(:second) + 300,
      "iat" => System.system_time(:second),
      "nonce" => session.nonce
    }

  defp sign(context, claims) do
    {:ok, token} =
      Assent.JWTAdapter.sign(claims, "RS256", context.private,
        json_library: Jason,
        private_key_id: "fixture-key"
      )

    token
  end

  defp token(context, session, changes \\ %{}),
    do: %{
      "id_token" => sign(context, Map.merge(claims(session), changes)),
      "access_token" => "ACCESS_TOKEN_SENTINEL",
      "refresh_token" => "REFRESH_TOKEN_SENTINEL",
      "token_type" => "Bearer",
      "expires_in" => 3600,
      "scope" => "openid email " <> @gmail,
      "provider_extra" => "discard"
    }

  defp old_token,
    do:
      Content.new(
        Jason.encode!(%{
          "access_token" => "OLD_ACCESS_SENTINEL",
          "refresh_token" => "REFRESH_TOKEN_SENTINEL",
          "scope" => "openid email " <> @gmail
        })
      )
end
