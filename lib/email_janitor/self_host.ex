defmodule EmailJanitor.SelfHost do
  @moduledoc "Opt-in single-user host facade. Owner arguments are server-verified Google subjects."
  alias EmailJanitor.SelfHost.{Cipher, Repo, Store}
  def config, do: Application.fetch_env!(:email_janitor, :self_host_config)

  def scope do
    {:ok, scope} = EmailJanitor.Store.Scope.new(Repo, "ej_selfhost")
    scope
  end

  def seal(label, id, content), do: Cipher.seal(config().credential_key, label, id, content)
  def open(label, id, cipher), do: Cipher.open(config().credential_key, label, id, cipher)
  defdelegate owner?(subject), to: Store
  defdelegate authorize_owner(result), to: Store
  defdelegate connect(subject, result, timezone), to: Store
  defdelegate inboxes(subject), to: Store
  defdelegate inbox(subject, id), to: Store
  defdelegate disconnect(subject, id), to: Store

  defdelegate respond(subject, inbox, conversation, request, content),
    to: EmailJanitor.SelfHost.Runtime

  @doc "Database-only authenticated host status; never calls a provider."
  def status(subject) do
    with {:ok, inboxes} <- inboxes(subject) do
      {:ok,
       %{
         inboxes: inboxes,
         google_configured: config().google_oauth != nil,
         model_provider: :bedrock,
         model_id: config().model_id
       }}
    end
  end

  @doc "Trusted conversation identity only; the host supplies current adapters separately."
  def conversation_context(subject, id) do
    with {:ok, inbox} <- inbox(subject, id) do
      {:ok, %{scope: scope(), inbox: inbox, owner_subject: subject}}
    end
  end
end
