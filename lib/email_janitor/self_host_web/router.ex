defmodule EmailJanitor.SelfHostWeb.Router do
  use Phoenix.Router
  import Phoenix.Controller
  import Plug.Conn
  alias EmailJanitor.SelfHostWeb.Auth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self' https://accounts.google.com; object-src 'none'",
      "referrer-policy" => "no-referrer",
      "cache-control" => "no-store"
    })

    plug(:current_owner)
  end

  scope "/", EmailJanitor.SelfHostWeb do
    pipe_through(:browser)
    get("/", Controller, :home, log: false)
    get("/accounts", Controller, :accounts, log: false)
    post("/accounts/:id/disconnect", Controller, :disconnect, log: false)
    get("/chat", Controller, :chat, log: false)
    post("/chat", Controller, :send_message, log: false)
    post("/auth/google", Controller, :authorize, log: false)
    get("/auth/google/callback", Controller, :callback, log: false)
    post("/logout", Controller, :logout, log: false)
  end

  defp current_owner(conn, _) do
    case Auth.fetch(get_session(conn, :session_token)) do
      {:ok, subject} ->
        assign(conn, :owner, subject)

      {:error, :session_unavailable} ->
        conn |> send_resp(503, "Janitor is temporarily unavailable. Please try again.") |> halt()

      _ ->
        assign(conn, :owner, nil)
    end
  end
end
