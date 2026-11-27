defmodule EmailJanitor.SelfHostWeb.WebTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Inbox, TestRepo}
  alias EmailJanitor.SelfHostWeb.{Auth, ChatLimit, Endpoint, TestHost}
  @endpoint Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = EmailJanitor.Store.Scope.new(TestRepo, "ej_test_a")

    keys = [
      :self_host_adapter,
      :browser_test_scope,
      :browser_test_observer,
      :browser_test_inboxes,
      :browser_test_response,
      Endpoint
    ]

    old = Map.new(keys, &{&1, Application.fetch_env(:email_janitor, &1)})
    Application.put_env(:email_janitor, :self_host_adapter, TestHost)
    Application.put_env(:email_janitor, :browser_test_scope, scope)
    Application.put_env(:email_janitor, :browser_test_observer, self())
    {:ok, box} = Inbox.new("browser-inbox", "owner@acme.com")

    Application.put_env(:email_janitor, :browser_test_inboxes, [
      %{inbox: box, state: :active, timezone: "Etc/UTC"}
    ])

    Application.put_env(:email_janitor, Endpoint,
      server: false,
      adapter: Bandit.PhoenixAdapter,
      secret_key_base: String.duplicate("s", 64),
      check_origin: ["https://janitor.test"],
      url: [scheme: "https", host: "janitor.test", port: 443],
      render_errors: [formats: [html: EmailJanitor.SelfHostWeb.ErrorHTML], layout: false]
    )

    start_supervised!(Endpoint)
    start_supervised!(ChatLimit)

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        case value do
          {:ok, value} -> Application.put_env(:email_janitor, key, value)
          :error -> Application.delete_env(:email_janitor, key)
        end
      end)
    end)

    %{scope: scope, box: box}
  end

  defp browser, do: build_conn() |> put_private(:plug_skip_csrf_protection, false)

  defp csrf(conn),
    do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, conn.resp_body) |> Enum.at(1)

  defp signed_in do
    {:ok, token} = Auth.issue("owner-subject", nil)
    browser() |> Plug.Test.init_test_session(%{session_token: Content.read(token)})
  end

  test "landing uses secure opaque cookies and loads the browser timezone helper" do
    conn = get(browser(), "/")
    assert html_response(conn, 200) =~ "Good email stays."
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    cookie = conn.resp_cookies["__Host-emailjanitor-selfhost"]
    assert cookie.secure and cookie.http_only and cookie.same_site == "Lax"
    assert response(get(browser(), "/assets/selfhost.js"), 200) =~ "Intl.DateTimeFormat"
    refute conn.resp_body =~ "Billing"
  end

  test "authentication and real CSRF protection cover private controls", t do
    for path <- ["/accounts", "/chat"] do
      assert redirected_to(get(browser(), path)) == "/"
    end

    for path <- ["/auth/google", "/chat", "/logout", "/accounts/" <> t.box.id <> "/disconnect"] do
      assert_error_sent(403, fn -> post(browser(), path, %{}) end)
    end
  end

  test "the composer calls only the authenticated inbox and escapes the model reply", t do
    page = get(signed_in(), "/chat")
    request_id = Ecto.UUID.generate()

    conn =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/chat", %{
        _csrf_token: csrf(page),
        inbox_id: t.box.id,
        request_id: request_id,
        message: "Keep invoices."
      })

    body = html_response(conn, 200)
    assert body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute body =~ "<script>alert"
    assert_receive {:respond, "owner-subject", inbox_id, conversation_id, ^request_id, content}
    assert inbox_id == t.box.id
    assert {:ok, _} = Ecto.UUID.cast(conversation_id)
    assert Content.read(content) == "Keep invoices."
  end

  test "a forged inbox cannot reach the provider and multiple accounts never silently choose the first",
       t do
    {:ok, second} = Inbox.new("second", "other@example.org")

    Application.put_env(:email_janitor, :browser_test_inboxes, [
      %{inbox: second, state: :active, timezone: "Etc/UTC"},
      %{inbox: %{t.box | address: "third@example.com"}, state: :active, timezone: "Etc/UTC"}
    ])

    page = get(signed_in(), "/chat")
    refute html_response(page, 200) =~ " selected"

    for id <- ["foreign-inbox", ""] do
      conn =
        page
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post("/chat", %{
          _csrf_token: csrf(page),
          inbox_id: id,
          request_id: Ecto.UUID.generate(),
          message: "Done."
        })

      assert html_response(conn, 400) =~ "Choose an inbox"
    end

    refute_receive {:respond, _, _, _, _, _}
  end

  test "a failed request has an explicit original retry and a fresh composer UUID", t do
    Application.put_env(
      :email_janitor,
      :browser_test_response,
      {:error, :conversation_unavailable}
    )

    page = get(signed_in(), "/chat")
    request_id = Ecto.UUID.generate()

    conn =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/chat", %{
        _csrf_token: csrf(page),
        inbox_id: t.box.id,
        request_id: request_id,
        message: "PRIVATE_RETRY_TEXT <script>"
      })

    body = html_response(conn, 503)
    assert body =~ "Retry that message"
    assert body =~ "PRIVATE_RETRY_TEXT &lt;script&gt;"

    ids =
      Regex.scan(~r/name="request_id" value="([^"]+)"/, body, capture: :all_but_first)
      |> List.flatten()

    assert request_id in ids
    assert Enum.any?(ids, &(&1 != request_id))
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute inspect(conn.resp_cookies) =~ "PRIVATE_RETRY_TEXT"
    refute_receive {:connected, _, _, _}
  end

  test "adapter exceptions cannot put request text into logs", t do
    Application.put_env(:email_janitor, :browser_test_response, :raise)
    page = get(signed_in(), "/chat")

    log =
      capture_log(fn ->
        conn =
          page
          |> recycle()
          |> put_private(:plug_skip_csrf_protection, false)
          |> post("/chat", %{
            _csrf_token: csrf(page),
            inbox_id: t.box.id,
            request_id: Ecto.UUID.generate(),
            message: "PRIVATE_RAISE_SENTINEL"
          })

        assert html_response(conn, 503) =~ "could not finish"
      end)

    refute log =~ "PRIVATE_RAISE_SENTINEL"
  end

  test "logout revokes the server-side session and disconnect is an authenticated CSRF action",
       t do
    page = get(signed_in(), "/accounts")

    conn =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/accounts/" <> t.box.id <> "/disconnect", %{_csrf_token: csrf(page)})

    assert redirected_to(conn) == "/accounts"
    assert_receive {:disconnected, "owner-subject", _}
    page = conn |> recycle() |> get("/accounts")

    conn =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/logout", %{_csrf_token: csrf(page)})

    assert redirected_to(conn) == "/"
    assert redirected_to(conn |> recycle() |> get("/accounts")) == "/"
  end
end
