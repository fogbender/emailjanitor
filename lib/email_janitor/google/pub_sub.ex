defmodule EmailJanitor.Google.PubSub do
  @moduledoc """
  Generated Pub/Sub SDK boundary for authenticated Gmail notification pull/ack.

  The host supplies a trusted subscription and a resolver for short-lived service
  access tokens. No global credentials, email bodies or raw SDK errors escape.
  A delivery is acknowledged only after its signal has been stored durably by
  the ingestion worker; pulling alone never acknowledges a message.
  """
  alias EmailJanitor.{Address, Content, TransportPrivacy}
  alias EmailJanitor.Gmail.BoundedResponse
  alias GoogleApi.PubSub.V1.{Api.Projects, Connection, Model}

  defmodule Config do
    @moduledoc "Trusted host-owned subscription and rotating service-token resolver."
    @enforce_keys [:subscription, :token_resolver]
    @derive {Inspect, only: [:subscription]}
    defstruct [:subscription, :token_resolver, :adapter]

    def new(subscription, resolver, opts \\ []) do
      if is_binary(subscription) and
           Regex.match?(
             ~r/\Aprojects\/[a-z][a-z0-9-]{4,28}[a-z0-9]\/subscriptions\/[A-Za-z][A-Za-z0-9_.~+%-]{2,254}\z/,
             subscription
           ) and
           is_function(resolver, 0) do
        {:ok,
         %__MODULE__{
           subscription: subscription,
           token_resolver: resolver,
           adapter: opts[:adapter]
         }}
      else
        {:error, :invalid_subscription}
      end
    end
  end

  defmodule Delivery do
    @moduledoc "Transient metadata signal; Pub/Sub message_id is unrelated to Gmail message IDs."
    @enforce_keys [:subscription, :ack_id, :message_id, :email_address, :history_id]
    @derive {Inspect, only: [:message_id, :email_address, :history_id]}
    @derive {Jason.Encoder, only: [:message_id, :email_address, :history_id]}
    defstruct @enforce_keys
  end

  def pull(%Config{} = config, max_messages \\ 100) do
    protect(fn ->
      with true <- is_integer(max_messages) and max_messages in 1..100,
           {:ok, connection} <- connection(config),
           {:ok, %Model.PullResponse{receivedMessages: received}} <-
             call(fn ->
               Projects.pubsub_projects_subscriptions_pull(connection, config.subscription,
                 body: %Model.PullRequest{maxMessages: max_messages}
               )
             end),
           received = if(is_nil(received), do: [], else: received),
           true <- is_list(received) and length(received) <= max_messages,
           {:ok, deliveries} <- parse_deliveries(received, config.subscription) do
        {:ok, deliveries}
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :invalid_notification}
      end
    end)
  end

  def acknowledge(%Config{} = config, deliveries) do
    protect(fn ->
      with true <- is_list(deliveries) and length(deliveries) in 1..100,
           {:ok, ids} <- acknowledgement_ids(deliveries, config.subscription),
           true <- length(Enum.uniq(ids)) == length(ids),
           {:ok, connection} <- connection(config),
           {:ok, _} <-
             call(fn ->
               Projects.pubsub_projects_subscriptions_acknowledge(connection, config.subscription,
                 body: %Model.AcknowledgeRequest{ackIds: ids}
               )
             end) do
        :ok
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :invalid_acknowledgement}
      end
    end)
  end

  defp connection(%Config{token_resolver: resolver} = config) do
    with :ok <- TransportPrivacy.check(),
         {:ok, token} <- resolver.(),
         token = if(match?(%Content{}, token), do: Content.read(token), else: token),
         true <- valid_text?(token, 16_384) do
      generated = Connection.new(token)

      transport =
        config.adapter ||
          {Tesla.Adapter.Httpc,
           [
             timeout: 35_000,
             connect_timeout: 10_000,
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ]
           ]}

      {:ok, Tesla.client([BoundedResponse | Tesla.Client.middleware(generated)], transport)}
    else
      _ -> {:error, :pubsub_unavailable}
    end
  end

  defp parse_deliveries(received, subscription) do
    Enum.reduce_while(received, {:ok, []}, fn item, {:ok, acc} ->
      case delivery(item, subscription) do
        {:ok, delivery} -> {:cont, {:ok, [delivery | acc]}}
        _ -> {:halt, {:error, :invalid_notification}}
      end
    end)
    |> case do
      {:ok, deliveries} -> {:ok, Enum.reverse(deliveries)}
      error -> error
    end
  end

  defp delivery(
         %Model.ReceivedMessage{
           ackId: ack,
           message: %Model.PubsubMessage{messageId: id, data: data}
         },
         subscription
       ) do
    with true <- valid_text?(ack, 4096) and valid_text?(id, 200),
         true <- valid_text?(data, 4096),
         {:ok, decoded} <- decode_data(data),
         true <- byte_size(decoded) <= 2048,
         {:ok, value} when is_map(value) <- Jason.decode(decoded),
         true <- Enum.sort(Map.keys(value)) == ~w(emailAddress historyId),
         {:ok, address} <- Address.normalize(value["emailAddress"]),
         true <- history_id?(value["historyId"]) do
      {:ok,
       %Delivery{
         subscription: subscription,
         ack_id: Content.new(ack),
         message_id: id,
         email_address: address,
         history_id: value["historyId"]
       }}
    else
      _ -> {:error, :invalid_notification}
    end
  end

  defp delivery(_, _), do: {:error, :invalid_notification}

  defp decode_data(data) do
    case Base.decode64(data, padding: false) do
      {:ok, _} = decoded -> decoded
      _ -> Base.url_decode64(data, padding: false)
    end
  end

  defp acknowledgement_ids(deliveries, subscription) do
    Enum.reduce_while(deliveries, {:ok, []}, fn
      %Delivery{subscription: ^subscription, ack_id: %Content{} = content}, {:ok, acc} ->
        ack = Content.read(content)

        if valid_text?(ack, 4096),
          do: {:cont, {:ok, [ack | acc]}},
          else: {:halt, {:error, :invalid_acknowledgement}}

      _, _ ->
        {:halt, {:error, :invalid_acknowledgement}}
    end)
  end

  defp history_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9]{1,32}\z/, id)

  defp valid_text?(text, limit),
    do:
      is_binary(text) and byte_size(text) in 1..limit and String.valid?(text) and
        not String.contains?(text, ["\r", "\n", <<0>>])

  defp call(operation) do
    case operation.() do
      {:ok, _} = result -> result
      {:error, %Tesla.Env{status: 401}} -> {:error, :authorization_required}
      {:error, %Tesla.Env{status: 403}} -> {:error, :forbidden}
      {:error, %Tesla.Env{status: 429}} -> {:error, :rate_limited}
      _ -> {:error, :pubsub_unavailable}
    end
  end

  defp protect(operation) do
    case operation.() do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, reason} = result when is_atom(reason) -> result
      _ -> {:error, :pubsub_unavailable}
    end
  rescue
    _ -> {:error, :pubsub_unavailable}
  catch
    _, _ -> {:error, :pubsub_unavailable}
  end
end
