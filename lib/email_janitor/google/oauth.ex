defmodule EmailJanitor.Google.OAuth do
  @moduledoc """
  Shared Google OAuth/OIDC boundary backed by Assent, with fixed Google endpoints.

  Hosts own attempt binding, expiry and single-use consumption. Keep Session dumps
  encrypted server-side; browser cookies must contain only an opaque attempt ID.
  This module stores nothing and returns credentials only inside redacted Content.
  """
  alias Assent.Strategy.{OIDC, OAuth2}
  alias EmailJanitor.{Address, Content}

  defmodule Config do
    @moduledoc "Trusted application settings; never build these from callback parameters."
    alias EmailJanitor.Content
    @enforce_keys [:client_id, :client_secret, :redirect_uri]
    @derive {Inspect, only: [:client_id, :redirect_uri]}
    defstruct [:client_id, :client_secret, :redirect_uri, http_options: []]

    def new(client_id, secret, redirect_uri) do
      with true <- text?(client_id, 4096),
           true <- text?(secret, 16_384),
           true <- text?(redirect_uri, 4096),
           %URI{host: host, scheme: scheme, userinfo: nil, fragment: nil} when is_binary(host) <-
             URI.parse(redirect_uri),
           true <-
             scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"]) do
        {:ok,
         %__MODULE__{
           client_id: client_id,
           client_secret: Content.new(secret),
           redirect_uri: redirect_uri
         }}
      else
        _ -> {:error, :invalid_oauth_config}
      end
    rescue
      _ -> {:error, :invalid_oauth_config}
    end

    defp text?(value, size),
      do:
        is_binary(value) and byte_size(value) in 1..size and String.valid?(value) and
          not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defmodule Session do
    @moduledoc "Redacted transient state, nonce and PKCE parameters; serialize with OAuth.dump_session/1."
    @enforce_keys [:state, :nonce, :code_verifier, :code_challenge, :code_challenge_method, :mode]
    @derive {Inspect, only: [:mode]}
    defstruct @enforce_keys

    defimpl Jason.Encoder do
      def encode(_, opts), do: Jason.Encode.string("[REDACTED]", opts)
    end
  end

  defmodule Result do
    @moduledoc "Verified Google identity and redacted, transient credential JSON."
    @enforce_keys [:subject, :email, :token]
    @derive {Inspect, only: [:subject, :email]}
    defstruct @enforce_keys

    defimpl Jason.Encoder do
      def encode(value, opts), do: Jason.Encode.map(Map.take(value, [:subject, :email]), opts)
    end
  end

  @gmail "https://www.googleapis.com/auth/gmail.modify"
  @openid %{
    "issuer" => "https://accounts.google.com",
    "authorization_endpoint" => "https://accounts.google.com/o/oauth2/v2/auth",
    "token_endpoint" => "https://oauth2.googleapis.com/token",
    "jwks_uri" => "https://www.googleapis.com/oauth2/v3/certs"
  }

  def authorize_url(%Config{} = config, mode) when mode in [:sign_in, :connect] do
    protect(:authorization_failed, fn ->
      params = [scope: if(mode == :connect, do: "email " <> @gmail, else: "email")]

      params =
        if mode == :connect,
          do: params ++ [access_type: "offline", prompt: "consent"],
          else: params

      with {:ok, %{url: url, session_params: params}} <-
             config
             |> settings()
             |> Keyword.put(:authorization_params, params)
             |> OIDC.authorize_url() do
        {:ok, %{url: url, session_params: struct!(Session, Map.put(params, :mode, mode))}}
      else
        _ -> {:error, :authorization_failed}
      end
    end)
  end

  def authorize_url(_, _), do: {:error, :invalid_oauth_config}

  def callback(%Config{} = config, %Session{} = session, params) when is_map(params) do
    protect(:authorization_failed, fn ->
      with :ok <- EmailJanitor.TransportPrivacy.check(),
           true <- valid_session?(session),
           true <- valid_callback?(params),
           {:ok, %{user: %{subject: subject, email: email}, token: raw}} <-
             config
             |> settings()
             |> Keyword.put(:session_params, Map.from_struct(session))
             |> OIDC.callback(Map.take(params, ~w(state code error)), __MODULE__),
           {:ok, token} <- sanitize_token(raw),
           true <- session.mode == :sign_in or @gmail in String.split(token["scope"]),
           true <- session.mode == :sign_in or valid_credential?(token["refresh_token"]) do
        {:ok, %Result{subject: subject, email: email, token: Content.new(Jason.encode!(token))}}
      else
        _ -> {:error, :authorization_failed}
      end
    end)
  end

  def callback(_, _, _), do: {:error, :authorization_failed}

  @doc false
  # Assent invokes this strategy hook after the code exchange. Signature, issuer,
  # audience, authorized party, expiry and nonce validation stay in the SDK.
  def fetch_user(settings, token) do
    with true <- valid_credential?(token["id_token"]),
         {:ok, %{claims: claims}} <- OIDC.validate_id_token(settings, token["id_token"]),
         true <- is_binary(claims["sub"]) and byte_size(claims["sub"]) in 1..255,
         true <- Regex.match?(~r/\A[!-~]+\z/, claims["sub"]),
         true <- is_integer(claims["exp"]) and claims["exp"] > System.system_time(:second),
         true <- is_integer(claims["iat"]) and claims["iat"] <= System.system_time(:second) + 30,
         true <- claims["email_verified"] === true,
         {:ok, email} <- Address.normalize(claims["email"]) do
      {:ok, %{subject: claims["sub"], email: email}}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  def refresh(%Config{} = config, %Content{} = content) do
    protect(:refresh_failed, fn ->
      with :ok <- EmailJanitor.TransportPrivacy.check(),
           true <- byte_size(Content.read(content)) <= 65_536,
           {:ok, old} when is_map(old) <- Jason.decode(Content.read(content)),
           true <- valid_credential?(old["refresh_token"]),
           {:ok, raw} <-
             refresh_access_token(settings(config), Map.take(old, ["refresh_token"])),
           raw =
             raw
             |> Map.put_new("refresh_token", old["refresh_token"])
             |> Map.put_new("scope", old["scope"]),
           {:ok, token} <- sanitize_token(raw) do
        {:ok, Content.new(Jason.encode!(token))}
      else
        {:error, :reauthorization_required} = error -> error
        _ -> {:error, :refresh_failed}
      end
    end)
  end

  def refresh(_, _), do: {:error, :refresh_failed}

  defp refresh_access_token(settings, previous) do
    case OAuth2.refresh_access_token(settings, previous) do
      {:ok, _} = result ->
        result

      {:error,
       %Assent.HTTPAdapter.InvalidResponseError{
         response: %Assent.HTTPAdapter.HTTPResponse{
           status: 400,
           body: %{"error" => "invalid_grant"}
         }
       }} ->
        {:error, :reauthorization_required}

      _ ->
        {:error, :refresh_failed}
    end
  end

  def dump_session(%Session{} = session) do
    if valid_session?(session) do
      session
      |> Map.from_struct()
      |> Map.update!(:mode, &Atom.to_string/1)
      |> Jason.encode!()
      |> Content.new()
    else
      raise ArgumentError, "invalid OAuth session"
    end
  end

  def load_session(%Content{} = content) do
    protect(:invalid_session, fn ->
      with true <- byte_size(Content.read(content)) <= 4096,
           {:ok, value} when is_map(value) <- Jason.decode(Content.read(content)),
           true <-
             Enum.sort(Map.keys(value)) ==
               ~w(code_challenge code_challenge_method code_verifier mode nonce state),
           mode when mode in ["sign_in", "connect"] <- value["mode"],
           session = %Session{
             state: value["state"],
             nonce: value["nonce"],
             code_verifier: value["code_verifier"],
             code_challenge: value["code_challenge"],
             code_challenge_method: value["code_challenge_method"],
             mode: if(mode == "sign_in", do: :sign_in, else: :connect)
           },
           true <- valid_session?(session) do
        {:ok, session}
      else
        _ -> {:error, :invalid_session}
      end
    end)
  end

  def load_session(_), do: {:error, :invalid_session}

  defp settings(%Config{} = config) do
    [
      client_id: config.client_id,
      client_secret: Content.read(config.client_secret),
      redirect_uri: config.redirect_uri,
      base_url: @openid["issuer"],
      trusted_issuers: ["accounts.google.com"],
      openid_configuration: @openid,
      token_url: @openid["token_endpoint"],
      client_authentication_method: :client_secret_post,
      id_token_signed_response_alg: "RS256",
      id_token_ttl_seconds: 600,
      nonce: true,
      state: true,
      code_verifier: true,
      json_library: Jason,
      jwt_adapter: Assent.JWTAdapter.AssentJWT,
      http_adapter:
        {Assent.HTTPAdapter.Req,
         Keyword.take(config.http_options, [:plug]) ++
           [
             retry: false,
             retry_log_level: false,
             redirect: false,
             decode_body: false,
             receive_timeout: 15_000,
             connect_options: [timeout: 10_000]
           ]}
    ]
  end

  defp valid_session?(%Session{} = session) do
    session.mode in [:sign_in, :connect] and session.code_challenge_method == "S256" and
      valid_random?(session.state, 32, 128) and valid_random?(session.nonce, 20, 128) and
      valid_random?(session.code_verifier, 43, 128) and
      is_binary(session.code_challenge) and
      Assent.constant_time_compare(
        session.code_challenge,
        Base.url_encode64(:crypto.hash(:sha256, session.code_verifier), padding: false)
      )
  end

  defp valid_random?(value, min, max),
    do:
      is_binary(value) and byte_size(value) in min..max and
        Regex.match?(~r/\A[A-Za-z0-9_+\/-]+\z/, value)

  defp valid_callback?(params),
    do:
      valid_credential?(params["code"]) and is_binary(params["state"]) and
        byte_size(params["state"]) <= 128 and not Map.has_key?(params, "error")

  defp sanitize_token(raw) when is_map(raw) do
    with true <- valid_credential?(raw["access_token"]),
         true <- raw["token_type"] in ["Bearer", "bearer"],
         seconds when is_integer(seconds) and seconds in 1..604_800 <- raw["expires_in"],
         scope when is_binary(scope) and byte_size(scope) <= 4096 <- raw["scope"],
         true <- is_nil(raw["refresh_token"]) or valid_credential?(raw["refresh_token"]) do
      token = %{
        "access_token" => raw["access_token"],
        "token_type" => "Bearer",
        "expires_at" => System.system_time(:second) + seconds,
        "scope" => scope
      }

      {:ok,
       if(is_nil(raw["refresh_token"]),
         do: token,
         else: Map.put(token, "refresh_token", raw["refresh_token"])
       )}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp sanitize_token(_), do: {:error, :invalid_token}

  defp valid_credential?(value),
    do:
      is_binary(value) and byte_size(value) in 1..32_768 and String.valid?(value) and
        not String.contains?(value, ["\r", "\n", <<0>>])

  defp protect(reason, operation) do
    case operation.() do
      {:ok, _} = value -> value
      {:error, :reauthorization_required} = value when reason == :refresh_failed -> value
      _ -> {:error, reason}
    end
  rescue
    _ -> {:error, reason}
  catch
    _, _ -> {:error, reason}
  end
end
