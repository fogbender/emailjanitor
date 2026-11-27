defmodule EmailJanitor.SelfHost.Adapters do
  @moduledoc "Trusted, explicit SDK capabilities for one self-hosted inbox."
  import Ecto.Query
  alias EmailJanitor.{Gmail, Inbox, Preferences, SelfHost}
  alias EmailJanitor.Google.{PubSub, ServiceToken}
  alias EmailJanitor.Mail.{Config, Outbox}
  alias EmailJanitor.Models
  alias EmailJanitor.SelfHost.{Binding, Credentials, Store}
  alias EmailJanitor.Store.Mailbox

  def gmail(ref) do
    with {:ok, _, inbox} <- Store.fetch_binding(ref),
         {:ok, config} <- Gmail.Config.new(inbox, fn -> Credentials.token(ref) end) do
      {:ok, {Gmail.SDK, [config: config]}}
    end
  end

  def model(config),
    do: Models.Config.new(:bedrock, config.model_id, nil, region: config.region)

  def preferences(inbox_id) do
    with {:ok, snapshot} <- Preferences.snapshot(SelfHost.scope(), inbox_id) do
      {:ok, Preferences.text(snapshot), snapshot.instruction_version}
    end
  end

  def mail(config) do
    Config.new(
      region: config.region,
      sender: config.mail["JANITOR_MAIL_SENDER"],
      bucket: config.mail["JANITOR_MAIL_BUCKET"],
      queue_url: config.mail["JANITOR_MAIL_QUEUE_URL"],
      topic_arn: config.mail["JANITOR_MAIL_TOPIC_ARN"],
      credentials: fn -> mail_credentials(config.region) end
    )
  end

  defp mail_credentials(region) do
    with {:ok, credentials} <- Models.AWSRole.fetch(region) do
      {:ok,
       [
         access_key_id: credentials[:access_key_id],
         secret_access_key: credentials[:secret_access_key],
         security_token: credentials[:session_token]
       ]}
    end
  end

  def pubsub(config) do
    path = config.pubsub["JANITOR_GOOGLE_TOKEN_FILE"]

    with true <- is_binary(path) and Path.type(path) == :absolute,
         {:ok, source} <-
           PubSub.Config.new(config.pubsub["JANITOR_GOOGLE_SUBSCRIPTION"], fn ->
             ServiceToken.read(path)
           end) do
      {:ok, {PubSub, source}}
    else
      _ -> {:error, :pubsub_not_configured}
    end
  end

  def self_mail(sender) do
    scope = SelfHost.scope()
    fn inbox, headers -> Outbox.self_delivery?(scope, inbox.id, sender, headers) end
  end

  @doc "DB-only routing; a deliberately disconnected account may be acknowledged without body access."
  def route(address) when is_binary(address) do
    scope = SelfHost.scope()

    matches =
      scope.repo.all(
        from(b in Binding,
          join: m in Mailbox,
          on: b.id == m.id,
          where: m.address == ^address,
          select: {b.id, b.epoch, b.state}
        ),
        prefix: scope.prefix
      )

    # Revoked-grant notifications can still become durable ID hints. They never
    # authorize body access; the worker separately requires a current grant.
    case Enum.filter(matches, fn {_, _, state} ->
           state in [:pending, :active, :reauthorization_required]
         end) do
      [{id, _, _}] ->
        {:ok, scope, %Inbox{id: id, address: address}}

      [] ->
        if matches != [] and Enum.all?(matches, fn {_, _, state} -> state == :disconnected end),
          do: {:ignore, :disconnected},
          else: {:error, :route_unavailable}

      _ ->
        {:error, :route_unavailable}
    end
  rescue
    _ -> {:error, :route_unavailable}
  end
end
