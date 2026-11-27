defmodule EmailJanitor.SelfHostWeb.TestHost do
  alias EmailJanitor.{Content, Inbox}
  def scope, do: Application.fetch_env!(:email_janitor, :browser_test_scope)

  def config,
    do: %{owner_email: "owner@acme.com", web_secret: Content.new(String.duplicate("s", 64))}

  def inboxes(owner) do
    if owner?(owner),
      do: {:ok, Application.get_env(:email_janitor, :browser_test_inboxes, [])},
      else: {:error, :unauthorized}
  end

  def inbox(owner, id) do
    with true <- owner?(owner),
         {:ok, rows} <- inboxes(owner),
         %{inbox: inbox} <-
           Enum.find(rows, &(&1.inbox.id == id and &1.state in [:pending, :active])),
         do: {:ok, inbox},
         else: (_ -> {:error, :not_connected})
  end

  def disconnect(owner, id) do
    with {:ok, _} <- inbox(owner, id) do
      send(
        Application.fetch_env!(:email_janitor, :browser_test_observer),
        {:disconnected, owner, id}
      )

      :ok
    end
  end

  def respond(owner, id, conversation, request, %Content{} = content) do
    send(
      Application.fetch_env!(:email_janitor, :browser_test_observer),
      {:respond, owner, id, conversation, request, content}
    )

    case Application.get_env(:email_janitor, :browser_test_response) do
      :raise -> raise Content.read(content)
      nil -> {:ok, Content.new("Instruction updated. <script>alert(1)</script>")}
      value -> value
    end
  end

  def owner?(subject), do: subject == "owner-subject"

  def authorize_owner(%{subject: "owner-subject", email: "owner@acme.com"}),
    do: {:ok, "owner-subject"}

  def authorize_owner(_), do: {:error, :unauthorized}

  def seal(label, id, value),
    do:
      EmailJanitor.SelfHost.Cipher.seal(Content.new(String.duplicate("k", 32)), label, id, value)

  def open(label, id, value),
    do:
      EmailJanitor.SelfHost.Cipher.open(Content.new(String.duplicate("k", 32)), label, id, value)

  def connect(owner, result, zone) do
    send(
      Application.fetch_env!(:email_janitor, :browser_test_observer),
      {:connected, owner, result.subject, zone}
    )

    Inbox.new("test-inbox", result.email)
  end
end

defmodule EmailJanitor.SelfHostWeb.TestOAuth do
  alias EmailJanitor.{Content, Google.OAuth}

  def authorize_url(_, mode) do
    verifier = String.duplicate("v", 43)

    session = %OAuth.Session{
      state: String.duplicate("r", 32),
      nonce: String.duplicate("n", 32),
      code_verifier: verifier,
      code_challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      code_challenge_method: "S256",
      mode: mode
    }

    {:ok,
     %{
       url: "https://accounts.google.com/o/oauth2/v2/auth?state=synthetic",
       session_params: session
     }}
  end

  defdelegate dump_session(session), to: OAuth
  defdelegate load_session(content), to: OAuth

  def callback(result, session, %{"code" => "valid", "state" => state}) do
    if state == session.state,
      do: {:ok, %{result | token: Content.new("SYNTHETIC_OAUTH_CREDENTIAL")}},
      else: {:error, :authorization_failed}
  end

  def callback(_, _, _), do: {:error, :authorization_failed}
end
