defmodule EmailJanitor.SelfHostWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :email_janitor

  plug(Plug.Static,
    at: "/assets",
    from: {:email_janitor, "priv/static"},
    only: ~w(selfhost.css selfhost.js)
  )

  # No request logger or parameter/body exporters, including OAuth callbacks.
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"], length: 65_536)

  plug(Plug.Session,
    store: :cookie,
    key: "__Host-emailjanitor-selfhost",
    path: "/",
    signing_salt: "ej-selfhost-sign-v1",
    encryption_salt: "ej-selfhost-encrypt-v1",
    same_site: "Lax",
    secure: true,
    http_only: true,
    max_age: 2_592_000
  )

  plug(EmailJanitor.SelfHostWeb.Router)
end

defmodule EmailJanitor.SelfHostWeb.ErrorHTML do
  def render(_, _), do: "The request could not be completed. Please try again."
end
