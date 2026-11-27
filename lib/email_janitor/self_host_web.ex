defmodule EmailJanitor.SelfHost.Web do
  @moduledoc "Optional single-user browser interface; never starts when the engine is used as a library."
  use Supervisor
  alias EmailJanitor.Content
  alias EmailJanitor.SelfHostWeb.{Auth, Endpoint, Migration}

  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  def init(config) do
    uri = URI.parse(config.public_url)
    {port, ""} = Integer.parse(System.get_env("JANITOR_WEB_PORT", "4000"))
    true = port in 1..65_535

    Application.put_env(:email_janitor, Endpoint,
      adapter: Bandit.PhoenixAdapter,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: port],
      url: [scheme: uri.scheme, host: uri.host, port: uri.port],
      check_origin: [config.public_url],
      secret_key_base: Content.read(config.web_secret),
      render_errors: [formats: [html: EmailJanitor.SelfHostWeb.ErrorHTML], layout: false]
    )

    Supervisor.init([EmailJanitor.SelfHostWeb.ChatLimit, Endpoint], strategy: :one_for_one)
  end

  def install(scope),
    do:
      Ecto.Migrator.up(scope.repo, 101, Migration,
        prefix: scope.prefix,
        log: false,
        telemetry_event: nil
      )

  def purge, do: Auth.purge()
end
