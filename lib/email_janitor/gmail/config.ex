defmodule EmailJanitor.Gmail.Config do
  @moduledoc """
  Host-owned Gmail connection. The host resolves rotating OAuth access tokens;
  this adapter never reads global Google, Codex, or Claude credentials.

  The resolver must refresh early and return an access token valid for at least
  the full 60-second execution budget. Preparation freezes that verified token;
  dispatch must not resolve or refresh credentials after an intent is admitted.

  `adapter` is a trusted Tesla transport override, useful for isolated tests.
  The default transport verifies TLS peers and does not redirect credentials.
  Custom transports must honor the mutation's 15-second total budget as well.
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
    httpc(30_000, 10_000)
  end

  def transport(%__MODULE__{adapter: adapter}), do: adapter

  @doc "Prepared dispatch must fit comfortably inside the owner's 30-second watchdog."
  def mutation_transport(%__MODULE__{adapter: nil}), do: httpc(10_000, 5_000)
  def mutation_transport(%__MODULE__{adapter: adapter}), do: adapter

  defp httpc(timeout, connect_timeout) do
    {Tesla.Adapter.Httpc,
     [
       timeout: timeout,
       connect_timeout: connect_timeout,
       ssl: [
         verify: :verify_peer,
         cacerts: :public_key.cacerts_get(),
         customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
       ]
     ]}
  end
end
