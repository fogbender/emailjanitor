defmodule EmailJanitor.Gmail.Config do
  @moduledoc """
  Host-owned Gmail connection. The host resolves rotating OAuth access tokens;
  this adapter never reads global Google, Codex, or Claude credentials.

  `adapter` is a trusted Tesla transport override, useful for isolated tests.
  The default transport verifies TLS peers and does not redirect credentials.
  """
  alias EmailJanitor.Inbox
  @enforce_keys [:inbox, :token_resolver]
  @derive {Inspect, only: [:inbox]}
  defstruct [:inbox, :token_resolver, :adapter, max_pages: 100]

  def new(%Inbox{} = inbox, resolver, opts \\ []) when is_function(resolver, 0) do
    pages = Keyword.get(opts, :max_pages, 100)

    if is_integer(pages) and pages in 1..1000 do
      {:ok,
       %__MODULE__{
         inbox: inbox,
         token_resolver: resolver,
         adapter: opts[:adapter],
         max_pages: pages
       }}
    else
      {:error, :invalid_gmail_config}
    end
  end

  def transport(%__MODULE__{adapter: nil}) do
    {Tesla.Adapter.Httpc,
     [
       timeout: 30_000,
       connect_timeout: 10_000,
       ssl: [
         verify: :verify_peer,
         cacerts: :public_key.cacerts_get(),
         customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
       ]
     ]}
  end

  def transport(%__MODULE__{adapter: adapter}), do: adapter
end
