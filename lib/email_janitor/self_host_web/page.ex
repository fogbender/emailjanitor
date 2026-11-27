defmodule EmailJanitor.SelfHostWeb.Page do
  @moduledoc false
  def render(name, a) do
    [
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
      "<title>Email Janitor</title><link rel=\"stylesheet\" href=\"/assets/selfhost.css\">",
      "<script src=\"/assets/selfhost.js\" defer></script></head><body>",
      "<header><a class=\"brand\" href=\"/\">email janitor</a>",
      navigation(a),
      "</header><main>",
      if(a.error, do: ["<p class=\"notice\" role=\"alert\">", h(a.error), "</p>"], else: []),
      content(name, a),
      "</main><footer>Less noise. Same inbox.</footer></body></html>"
    ]
  end

  defp navigation(%{owner: nil}), do: []

  defp navigation(a),
    do: [
      "<nav><a href=\"/accounts\">Accounts</a><a href=\"/chat\">Chat</a>",
      form("/logout", a, "Sign out", []),
      "</nav>"
    ]

  defp content(:home, a),
    do: [
      "<p class=\"eyebrow\">A little help for your inbox</p><h1>Good email stays.<br>The rest gets done.</h1>",
      "<p class=\"intro\">Keep using your email client. Janitor quietly clears unwanted sales pitches. ",
      "Teach it by replying to your daily email, or chat here.</p>",
      form("/auth/google", a, "Sign in with Google", [
        hidden("mode", "sign_in"),
        hidden("timezone", "Etc/UTC")
      ])
    ]

  defp content(:accounts, a),
    do: [
      "<p class=\"eyebrow\">Your accounts</p><h1>One Janitor.<br>All your inboxes.</h1><ul class=\"accounts\">",
      Enum.map(a.inboxes, fn row ->
        [
          "<li><div><strong>",
          h(row.inbox.address),
          "</strong><small>",
          status(row.state),
          " · ",
          h(row.timezone),
          "</small></div>",
          if(row.state != :disconnected,
            do:
              form(
                "/accounts/" <> URI.encode_www_form(row.inbox.id) <> "/disconnect",
                a,
                "Disconnect",
                []
              ),
            else: []
          ),
          "</li>"
        ]
      end),
      "</ul>",
      form("/auth/google", a, "Connect Google account", [
        hidden("mode", "connect"),
        hidden("timezone", "Etc/UTC")
      ]),
      "<p class=\"quiet\">Daily activity emails arrive at 9pm in each account’s timezone, only on days with activity.</p>"
    ]

  defp content(:chat, a),
    do: [
      "<p class=\"eyebrow\">Talk to Janitor</p><h1>Tell me what<br>should stay or go.</h1>",
      "<p>Correct a cleanup, make an exception, or ask what happened.</p>",
      if(a.reply, do: ["<div class=\"reply\" role=\"status\">", h(a.reply), "</div>"], else: []),
      retry(a),
      if(Enum.any?(a.inboxes, &(&1.state != :disconnected)),
        do: chat_form(a),
        else: "<p><a href=\"/accounts\">Connect a Google account</a> to get started.</p>"
      )
    ]

  # The original text stays only in this escaped, no-store response DOM. A retry
  # reuses its request UUID; a newly typed message always gets a fresh UUID.
  defp retry(%{retry: nil}), do: []

  defp retry(a),
    do:
      form("/chat", a, "Retry that message", [
        hidden("request_id", a.retry.request_id),
        hidden("inbox_id", a.retry.inbox_id),
        hidden("message", a.retry.message)
      ])

  defp chat_form(a),
    do: [
      "<form method=\"post\" action=\"/chat\">",
      hidden("_csrf_token", a.csrf),
      hidden("request_id", a.request_id),
      "<label for=\"inbox\">Inbox</label><select id=\"inbox\" name=\"inbox_id\" required>",
      "<option value=\"\">Choose an inbox</option>",
      a.inboxes
      |> Enum.reject(&(&1.state == :disconnected))
      |> Enum.map(fn row ->
        [
          "<option value=\"",
          h(row.inbox.id),
          "\"",
          if(row.inbox.id == a.inbox_id, do: " selected", else: ""),
          ">",
          h(row.inbox.address),
          "</option>"
        ]
      end),
      "</select><label for=\"message\">Your message</label>",
      "<textarea id=\"message\" name=\"message\" maxlength=\"16000\" rows=\"4\" required placeholder=\"Bob’s email should have stayed in my inbox.\"></textarea>",
      "<button type=\"submit\">Send to Janitor</button></form>"
    ]

  defp status(:active), do: "Connected"
  defp status(:pending), do: "Connecting"
  defp status(:reauthorization_required), do: "Reconnect needed"
  defp status(_), do: "Disconnected"

  defp form(path, a, label, fields),
    do: [
      "<form method=\"post\" action=\"",
      h(path),
      "\">",
      hidden("_csrf_token", a.csrf),
      fields,
      "<button type=\"submit\">",
      h(label),
      "</button></form>"
    ]

  defp hidden(key, value),
    do: ["<input type=\"hidden\" name=\"", h(key), "\" value=\"", h(value), "\">"]

  defp h(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
