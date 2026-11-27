defmodule EmailJanitor.Mail.Feedback.Route do
  @enforce_keys [:key, :inbox_id]
  defstruct @enforce_keys
end

defmodule EmailJanitor.Mail.Feedback.Context do
  @moduledoc "Host-built command context. Keys contain only opaque identifiers; callbacks are never derived from email content."
  @enforce_keys [:key, :scope, :inbox, :conversation_id, :guard, :respond, :render]
  @derive {Inspect, only: [:inbox, :conversation_id]}
  defstruct @enforce_keys ++ [verified_reference: false]
end

defmodule EmailJanitor.Mail.Feedback.Binding do
  @moduledoc "Current sender-inbox binding; verified Sent headers may select a command inbox in this same scope."
  @enforce_keys [:scope, :inbox, :gmail, :guard, :route_verified, :restore_context]
  @derive {Inspect, only: [:inbox]}
  defstruct @enforce_keys
end

defmodule EmailJanitor.Mail.Feedback.Config do
  @enforce_keys [:transport_scope, :transport_inbox, :mail, :parser_executable, :route, :resolve]
  @derive {Inspect, only: [:transport_inbox]}
  defstruct @enforce_keys ++ [signup_url: nil]
  alias EmailJanitor.{Inbox, Mail, Store.Scope}

  def new(opts) do
    with %Scope{} = scope <- opts[:transport_scope],
         %Inbox{} = inbox <- opts[:transport_inbox],
         %Mail.Config{} = mail <- opts[:mail],
         true <- inbox.address == mail.sender,
         parser when is_binary(parser) <- opts[:parser_executable],
         true <- Path.type(parser) == :absolute,
         {:ok, %{type: :regular, mode: mode}} <- File.stat(parser),
         true <- Bitwise.band(mode, 0o111) != 0,
         route when is_function(route, 1) <- opts[:route],
         resolve when is_function(resolve, 1) <- opts[:resolve],
         true <- signup?(opts[:signup_url]) do
      {:ok,
       %__MODULE__{
         transport_scope: scope,
         transport_inbox: inbox,
         mail: mail,
         parser_executable: parser,
         route: route,
         resolve: resolve,
         signup_url: opts[:signup_url]
       }}
    else
      _ -> {:error, :invalid_feedback_configuration}
    end
  end

  def opaque_key?(value),
    do:
      is_binary(value) and byte_size(value) in 1..1024 and
        Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp signup?(nil), do: true

  defp signup?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp signup?(_), do: false
end
