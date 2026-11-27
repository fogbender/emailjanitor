# Loopback-only synthetic host, never compiled into the release.
if System.get_env("JANITOR_ENABLE_SELF_HOST") == "1",
  do: raise("Disable deployed services before running the browser fixture")

{:ok, _} = Application.ensure_all_started(:email_janitor)

defmodule BrowserHost do
  alias EmailJanitor.{Content, Inbox}
  alias EmailJanitor.SelfHostWeb.TestHost
  defdelegate scope(), to: TestHost
  defdelegate config(), to: TestHost
  defdelegate inboxes(owner), to: TestHost
  defdelegate inbox(owner, id), to: TestHost
  defdelegate owner?(owner), to: TestHost
  defdelegate authorize_owner(result), to: TestHost
  defdelegate seal(label, id, content), to: TestHost
  defdelegate open(label, id, value), to: TestHost

  def connect(owner, result, zone) do
    true = owner?(owner)
    {:ok, inbox} = Inbox.new("browser-inbox", result.email)
    Application.put_env(:email_janitor, :browser_test_inboxes, [
      %{inbox: inbox, state: :active, timezone: zone}
    ])
    {:ok, inbox}
  end

  def disconnect(owner, id) do
    {:ok, _} = inbox(owner, id)
    Application.put_env(:email_janitor, :browser_test_inboxes, [])
    :ok
  end

  def respond(owner, inbox_id, _, request_id, content) do
    {:ok, _} = inbox(owner, inbox_id)
    first = Agent.get_and_update(__MODULE__.Seen, fn seen ->
      {not MapSet.member?(seen, request_id), MapSet.put(seen, request_id)}
    end)
    if first and String.starts_with?(Content.read(content), "BROWSER_EMAIL_BODY_SENTINEL: retry"),
      do: {:error, :synthetic_unavailable},
      else: {:ok, Content.new("I updated your instructions. You can correct me here anytime.")}
  end
end

dir = System.fetch_env!("JANITOR_BROWSER_DIR")
port = System.fetch_env!("JANITOR_BROWSER_PORT") |> String.to_integer()
{:ok, _} = EmailJanitor.TestRepo.start_link(
  socket_dir: dir, database: "emailjanitor_browser", username: System.fetch_env!("USER"),
  port: 5432, log: false
)
{:ok, scope} = EmailJanitor.Store.Scope.new(EmailJanitor.TestRepo, "ej_browser")
:ok = EmailJanitor.Store.install(scope)
EmailJanitor.SelfHost.Web.install(scope)
Application.put_env(:email_janitor, :browser_test_scope, scope)
Application.put_env(:email_janitor, :self_host_adapter, BrowserHost)
Application.put_env(:email_janitor, :self_host_oauth, {
  EmailJanitor.SelfHostWeb.TestOAuth,
  %EmailJanitor.Google.OAuth.Result{subject: "owner-subject", email: "owner@acme.com", token: EmailJanitor.Content.new("synthetic")}
})
{:ok, _} = Agent.start_link(fn -> MapSet.new() end, name: BrowserHost.Seen)
{:ok, _} = EmailJanitor.SelfHostWeb.ChatLimit.start_link()
endpoint = EmailJanitor.SelfHostWeb.Endpoint
Application.put_env(:email_janitor, endpoint,
  server: false, adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("synthetic-browser-key-", 5),
  url: [scheme: "https", host: "localhost", port: port],
  check_origin: ["https://localhost:#{port}"],
  render_errors: [formats: [html: EmailJanitor.SelfHostWeb.ErrorHTML], layout: false]
)
{:ok, _} = endpoint.start_link()
{:ok, _} = Bandit.start_link(
  plug: endpoint, scheme: :https, ip: {127, 0, 0, 1}, port: port,
  keyfile: Path.join(dir, "key.pem"), certfile: Path.join(dir, "cert.pem")
)
Process.sleep(:infinity)
