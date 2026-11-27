defmodule EmailJanitor.SelfHostWeb.Auth do
  @moduledoc "Opaque, revocable browser sessions and single-use, browser-bound Google OAuth attempts."
  import Ecto.Query
  alias EmailJanitor.Content

  defmodule Session do
    use Ecto.Schema
    @primary_key {:id, :binary, []}
    schema "selfhost_web_sessions" do
      field(:subject, :string)
      field(:issued_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
    end
  end

  defmodule Attempt do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    @derive {Inspect, only: [:id, :mode, :expires_at]}
    schema "selfhost_web_attempts" do
      field(:browser_hash, :binary)
      field(:session_hash, :binary)
      field(:subject, :string)
      field(:mode, Ecto.Enum, values: [:sign_in, :connect])
      field(:timezone, :string)
      field(:ciphertext, :binary)
      field(:expires_at, :utc_datetime_usec)
    end
  end

  def host, do: Application.get_env(:email_janitor, :self_host_adapter, EmailJanitor.SelfHost)

  def gateway do
    Application.get_env(:email_janitor, :self_host_oauth) ||
      {EmailJanitor.Google.OAuth, host().config().google_oauth}
  end

  def fetch(token, now \\ DateTime.utc_now()) do
    with {:ok, hash} <- digest(token),
         scope = host().scope(),
         %Session{} = row <- scope.repo.get(Session, hash, options(scope)),
         true <- DateTime.compare(row.expires_at, now) == :gt,
         true <- DateTime.compare(row.issued_at, DateTime.add(now, 30)) != :gt,
         true <- host().owner?(row.subject) do
      {:ok, row.subject}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :session_unavailable}
  catch
    _, _ -> {:error, :session_unavailable}
  end

  def issue(subject, previous_token, now \\ DateTime.utc_now()) do
    with true <- host().owner?(subject) do
      scope = host().scope()
      token = random()

      scope.repo.transaction(
        fn ->
          scope.repo.insert!(
            %Session{
              id: hash(token),
              subject: subject,
              issued_at: now,
              expires_at: DateTime.add(now, 2_592_000)
            },
            options(scope)
          )

          case revoke(previous_token) do
            :ok -> Content.new(token)
            _ -> scope.repo.rollback(:session_unavailable)
          end
        end,
        options(scope)
      )
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :session_unavailable}
  catch
    _, _ -> {:error, :session_unavailable}
  end

  def revoke(token) do
    case digest(token) do
      {:ok, id} ->
        scope = host().scope()
        scope.repo.delete_all(from(s in Session, where: s.id == ^id), options(scope))

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> {:error, :session_unavailable}
  end

  def begin(mode, session_token, timezone, now \\ DateTime.utc_now())
      when mode in [:sign_in, :connect] do
    with {:ok, subject, session_hash} <- initiator(session_token, now),
         true <- mode == :sign_in or is_binary(subject),
         true <- is_binary(timezone) and byte_size(timezone) <= 128,
         {:ok, _} <- DateTime.shift_zone(now, timezone, Tzdata.TimeZoneDatabase),
         {adapter, config} = gateway(),
         {:ok, %{url: url, session_params: session}} <- adapter.authorize_url(config, mode),
         %Content{} = serialized <- adapter.dump_session(session) do
      scope = host().scope()
      id = Ecto.UUID.generate()
      browser_token = random()

      with {:ok, ciphertext} <- host().seal("browser-oauth", id, serialized) do
        scope.repo.insert!(
          %Attempt{
            id: id,
            browser_hash: hash(browser_token),
            subject: subject,
            session_hash: session_hash,
            mode: mode,
            timezone: timezone,
            ciphertext: ciphertext,
            expires_at: DateTime.add(now, 600)
          },
          options(scope)
        )

        purge(now)
        {:ok, %{url: url, browser_token: browser_token}}
      end
    else
      _ -> {:error, :google_unavailable}
    end
  rescue
    _ -> {:error, :google_unavailable}
  catch
    _, _ -> {:error, :google_unavailable}
  end

  def complete(browser_token, params, session_token, now \\ DateTime.utc_now()) do
    with {:ok, browser_hash} <- digest(browser_token),
         {:ok, subject, session_hash} <- initiator(session_token, now),
         {:ok, attempt} <- claim(browser_hash, subject, session_hash, now),
         {:ok, serialized} <- host().open("browser-oauth", attempt.id, attempt.ciphertext),
         {adapter, config} = gateway(),
         {:ok, session} <- adapter.load_session(serialized),
         {:ok, %EmailJanitor.Google.OAuth.Result{} = result} <-
           adapter.callback(config, session, Map.take(params, ~w(code state error))),
         {:ok, owner} <- finish(attempt, result) do
      issue(owner, session_token, now)
    else
      _ -> {:error, :google_unavailable}
    end
  rescue
    _ -> {:error, :google_unavailable}
  catch
    _, _ -> {:error, :google_unavailable}
  end

  def purge(now \\ DateTime.utc_now()) do
    scope = host().scope()
    scope.repo.delete_all(from(a in Attempt, where: a.expires_at <= ^now), options(scope))
    scope.repo.delete_all(from(s in Session, where: s.expires_at <= ^now), options(scope))
    :ok
  end

  defp finish(%{mode: :sign_in}, result), do: host().authorize_owner(result)

  defp finish(%{mode: :connect, subject: subject, timezone: timezone}, result) do
    with true <- host().owner?(subject),
         {:ok, _} <- host().connect(subject, result, timezone),
         do: {:ok, subject}
  end

  defp claim(browser_hash, subject, session_hash, now) do
    scope = host().scope()

    scope.repo.transaction(
      fn ->
        row =
          scope.repo.one(
            from(a in Attempt, where: a.browser_hash == ^browser_hash, lock: "FOR UPDATE"),
            options(scope)
          )

        if is_nil(row) or DateTime.compare(row.expires_at, now) != :gt or
             row.subject != subject or row.session_hash != session_hash do
          scope.repo.rollback(:invalid_attempt)
        end

        scope.repo.delete!(row, options(scope))
        row
      end,
      options(scope)
    )
  end

  defp initiator(nil, _), do: {:ok, nil, nil}

  defp initiator(token, now) do
    case fetch(token, now) do
      {:ok, subject} -> {:ok, subject, hash(token)}
      {:error, :unauthorized} -> {:ok, nil, nil}
      _ -> {:error, :session_unavailable}
    end
  end

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash(token), do: :crypto.hash(:sha256, token)

  defp digest(token) when is_binary(token) and byte_size(token) == 43 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, token),
      do: {:ok, hash(token)},
      else: {:error, :unauthorized}
  end

  defp digest(_), do: {:error, :unauthorized}
  defp options(scope), do: [prefix: scope.prefix, log: false, telemetry_event: nil]
end
