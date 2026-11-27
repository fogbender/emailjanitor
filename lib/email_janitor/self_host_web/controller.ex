defmodule EmailJanitor.SelfHostWeb.Controller do
  use Phoenix.Controller, formats: [:html]
  alias EmailJanitor.Content
  alias EmailJanitor.SelfHostWeb.{Auth, ChatLimit, Page}
  plug(:require_owner when action in [:accounts, :disconnect, :chat, :send_message])

  def home(%{assigns: %{owner: nil}} = conn, _), do: page(conn, :home)
  def home(conn, _), do: redirect(conn, to: "/accounts")

  def accounts(conn, _) do
    with {:ok, inboxes} <- Auth.host().inboxes(conn.assigns.owner) do
      page(conn, :accounts, %{inboxes: inboxes})
    else
      _ -> unavailable(conn)
    end
  end

  def disconnect(conn, %{"id" => id}) do
    case Auth.host().disconnect(conn.assigns.owner, id) do
      :ok -> redirect(conn, to: "/accounts")
      _ -> unavailable(conn)
    end
  end

  def chat(conn, params), do: chat_page(conn, params)

  def send_message(conn, params) do
    with {:ok, inboxes} <- Auth.host().inboxes(conn.assigns.owner),
         {:ok, inbox} <- selected(conn, inboxes, params["inbox_id"]),
         text when is_binary(text) and byte_size(text) in 1..16_000 <- params["message"],
         {:ok, request_id} <- Ecto.UUID.cast(params["request_id"]) do
      result =
        ChatLimit.run(fn ->
          Auth.host().respond(
            conn.assigns.owner,
            inbox.id,
            conversation_id(conn.assigns.owner, inbox.id),
            request_id,
            Content.new(text)
          )
        end)

      case result do
        {:ok, %Content{} = reply} ->
          chat_page(conn, params, %{reply: Content.read(reply)})

        _ ->
          chat_page(put_status(conn, 503), params, %{
            error: "Janitor could not finish that message. Please try again.",
            retry: %{request_id: request_id, message: text, inbox_id: inbox.id}
          })
      end
    else
      _ ->
        chat_page(put_status(conn, 400), params, %{error: "Choose an inbox and enter a message."})
    end
  rescue
    _ -> unavailable(conn)
  catch
    _, _ -> unavailable(conn)
  end

  def authorize(conn, params) do
    mode = if params["mode"] == "connect", do: :connect, else: :sign_in

    with {:ok, flow} <-
           Auth.begin(mode, get_session(conn, :session_token), params["timezone"] || "Etc/UTC") do
      conn
      |> put_session(:oauth_browser_token, flow.browser_token)
      |> redirect(external: flow.url)
    else
      _ -> unavailable(conn)
    end
  end

  def callback(conn, params) do
    browser_token = get_session(conn, :oauth_browser_token)
    conn = delete_session(conn, :oauth_browser_token)

    case Auth.complete(browser_token, params, get_session(conn, :session_token)) do
      {:ok, token} ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:session_token, Content.read(token))
        |> redirect(to: "/accounts")

      _ ->
        page(put_status(conn, 400), :home, %{
          error: "Google sign-in did not complete. Please start again."
        })
    end
  end

  def logout(conn, _) do
    case Auth.revoke(get_session(conn, :session_token)) do
      :ok -> conn |> configure_session(drop: true) |> redirect(to: "/")
      _ -> unavailable(conn)
    end
  end

  defp chat_page(conn, params, extra \\ %{}) do
    with {:ok, inboxes} <- Auth.host().inboxes(conn.assigns.owner) do
      chosen =
        case selected(conn, inboxes, params["inbox_id"]) do
          {:ok, inbox} -> inbox.id
          _ -> nil
        end

      page(conn, :chat, Map.merge(%{inboxes: inboxes, inbox_id: chosen}, extra))
    else
      _ -> unavailable(conn)
    end
  end

  defp selected(conn, inboxes, id) when is_binary(id) and byte_size(id) in 1..256 do
    with true <- Enum.any?(inboxes, &(&1.inbox.id == id and &1.state != :disconnected)),
         {:ok, inbox} <- Auth.host().inbox(conn.assigns.owner, id),
         do: {:ok, inbox}
  end

  defp selected(conn, inboxes, nil) do
    active = Enum.reject(inboxes, &(&1.state == :disconnected))
    matches = Enum.filter(active, &(&1.inbox.address == Auth.host().config().owner_email))

    case {active, matches} do
      {[%{inbox: inbox}], _} -> Auth.host().inbox(conn.assigns.owner, inbox.id)
      {_, [%{inbox: inbox}]} -> Auth.host().inbox(conn.assigns.owner, inbox.id)
      _ -> {:error, :choose_inbox}
    end
  end

  defp selected(_, _, _), do: {:error, :choose_inbox}

  defp conversation_id(owner, inbox_id) do
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
      :crypto.mac(
        :hmac,
        :sha256,
        Content.read(Auth.host().config().web_secret),
        "selfhost-conversation:" <> owner <> ":" <> inbox_id
      )

    Ecto.UUID.load!(<<a::48, 4::4, b::12, 2::2, c::62>>)
  end

  defp require_owner(%{assigns: %{owner: nil}} = conn, _), do: conn |> redirect(to: "/") |> halt()
  defp require_owner(conn, _), do: conn

  defp unavailable(conn),
    do:
      page(put_status(conn, 503), :home, %{
        error: "Janitor is temporarily unavailable. Please try again."
      })

  defp page(conn, name, extra \\ %{}),
    do:
      html(
        conn,
        Page.render(
          name,
          Map.merge(
            %{
              owner: conn.assigns.owner,
              csrf: get_csrf_token(),
              error: nil,
              reply: nil,
              retry: nil,
              request_id: Ecto.UUID.generate()
            },
            extra
          )
        )
      )
end
