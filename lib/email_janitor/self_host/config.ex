defmodule EmailJanitor.SelfHost.Config do
  @moduledoc "Trusted single-user host settings. Secrets come from bounded runtime files."
  alias EmailJanitor.{Address, Content}
  alias EmailJanitor.Google.OAuth

  @derive {Inspect, only: [:owner_email, :public_url, :enable_web, :region, :model_id]}
  defstruct [
    :owner_email,
    :public_url,
    :google_oauth,
    :credential_key,
    :web_secret,
    :reply_parser_executable,
    :database,
    :mail,
    :pubsub,
    enable_web: true,
    region: "us-east-1",
    model_id: "amazon.nova-micro-v1:0"
  ]

  def enabled?, do: System.get_env("JANITOR_ENABLE_SELF_HOST") == "1"

  def load(env \\ System.get_env()) when is_map(env) do
    with {:ok, owner} <- Address.normalize(env["JANITOR_OWNER_EMAIL"]),
         {:ok, public_url} <- public_url(env["JANITOR_PUBLIC_URL"]),
         {:ok, key} <- secret(env["JANITOR_CREDENTIAL_KEY_FILE"], 32, 32),
         {:ok, web_secret} <- secret(env["JANITOR_SECRET_KEY_BASE_FILE"], 64, 4096),
         {:ok, google} <- google(env["JANITOR_GOOGLE_CLIENT_JSON_FILE"], public_url),
         {:ok, google} <- revocation(google, env["JANITOR_GOOGLE_REVOKE_EXECUTABLE"]),
         {:ok, database} <- database(env),
         parser <- env["JANITOR_REPLY_PARSER_EXECUTABLE"],
         true <- is_nil(parser) or (is_binary(parser) and Path.type(parser) == :absolute),
         region when is_binary(region) <- Map.get(env, "AWS_REGION", "us-east-1"),
         true <- region == "us-east-1",
         model when is_binary(model) <-
           Map.get(env, "JANITOR_MODEL_ID", "amazon.nova-micro-v1:0"),
         {:ok, _} <- EmailJanitor.Models.Config.new(:bedrock, model, nil, region: region),
         true <- Map.get(env, "JANITOR_MODEL_PROVIDER", "bedrock") == "bedrock",
         web when web in ["0", "1"] <- Map.get(env, "JANITOR_ENABLE_SELF_HOST_WEB", "1") do
      {:ok,
       %__MODULE__{
         owner_email: owner,
         public_url: public_url,
         credential_key: Content.new(key),
         web_secret: Content.new(web_secret),
         reply_parser_executable: parser,
         google_oauth: google,
         database: database,
         enable_web: web == "1",
         region: region,
         model_id: model,
         mail:
           Map.take(
             env,
             ~w(JANITOR_MAIL_SENDER JANITOR_MAIL_BUCKET JANITOR_MAIL_QUEUE_URL JANITOR_MAIL_TOPIC_ARN)
           ),
         pubsub:
           Map.take(
             env,
             ~w(JANITOR_GOOGLE_PROJECT JANITOR_GOOGLE_TOPIC JANITOR_GOOGLE_SUBSCRIPTION JANITOR_GOOGLE_TOKEN_FILE)
           )
       }}
    else
      _ -> {:error, :invalid_self_host_config}
    end
  rescue
    _ -> {:error, :invalid_self_host_config}
  end

  defp public_url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: scheme,
         host: host,
         port: port,
         path: path,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) and host != "" and path in [nil, "/"] and port in 1..65_535 ->
        if valid_host?(host) and not Regex.match?(~r/:(?:0[0-9]*|)\/?\z/, value) and
             (scheme == "https" or
                (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])),
           do: {:ok, String.trim_trailing(value, "/")},
           else: :error

      _ ->
        :error
    end
  end

  defp public_url(_), do: :error

  defp valid_host?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, _} ->
        true

      _ ->
        not match?({:ok, _}, :inet.parse_address(String.to_charlist(host))) and
          not Regex.match?(
            ~r/\A(?:[0-9]+|0[xX][a-fA-F0-9]*)\z/,
            List.last(String.split(host, "."))
          ) and
          byte_size(host) <= 253 and not Regex.match?(~r/\A[0-9.]+\z/, host) and
          Enum.all?(String.split(host, "."), fn label ->
            Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, label)
          end)
    end
  end

  defp database(env) do
    socket = Map.get(env, "JANITOR_DATABASE_SOCKET", "/run/postgresql")
    name = Map.get(env, "JANITOR_DATABASE_NAME", "emailjanitor")
    user = Map.get(env, "JANITOR_DATABASE_USER", "emailjanitor")

    if is_binary(socket) and Path.type(socket) == :absolute and
         Enum.all?(
           [name, user],
           &(is_binary(&1) and Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/, &1))
         ) do
      {:ok,
       [
         socket_dir: socket,
         database: name,
         username: user,
         port: 5432,
         pool_size: 10,
         log: false,
         show_sensitive_data_on_connection_error: false
       ]}
    else
      :error
    end
  end

  defp revocation(nil, nil), do: {:ok, nil}
  defp revocation(google, nil), do: {:ok, google}

  defp revocation(%OAuth.Config{} = google, path) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: {:ok, %{google | revocation_executable: path}},
      else: :error
  end

  defp revocation(_, _), do: :error

  defp google(nil, _), do: {:ok, nil}

  defp google(path, public_url) do
    redirect = public_url <> "/auth/google/callback"

    with {:ok, bytes} <- secret(path, 1, 32_768),
         {:ok, %{"web" => client}} <- Jason.decode(bytes),
         true <- is_list(client["redirect_uris"]) and redirect in client["redirect_uris"],
         {:ok, config} <- OAuth.Config.new(client["client_id"], client["client_secret"], redirect) do
      {:ok, config}
    else
      _ -> :error
    end
  end

  defp secret(path, minimum, maximum) when is_binary(path) do
    with true <- Path.type(path) == :absolute and not String.starts_with?(path, "/nix/store/"),
         {:ok, %{type: :regular, size: size, mode: mode}}
         when size >= minimum and size <= maximum <- File.stat(path),
         true <- Bitwise.band(mode, 0o027) == 0,
         {:ok, bytes} <-
           File.open(path, [:read, :binary], fn file -> IO.binread(file, maximum + 1) end),
         true <- is_binary(bytes) and byte_size(bytes) in minimum..maximum do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp secret(_, _, _), do: :error
end
