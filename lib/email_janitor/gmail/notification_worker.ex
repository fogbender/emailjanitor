defmodule EmailJanitor.Gmail.NotificationWorker do
  @moduledoc """
  One bounded pull/record/ack step, suitable for a host's supervised scheduler.

  A trusted host router maps a verified notification email to its storage scope
  and Inbox. It must never derive scopes from request/model parameters. Unknown
  routes, uninitialized connections and failed commits remain unacknowledged.
  A successful durable signal may be redelivered; recording and ack are idempotent.
  Store the complete pull before one batched acknowledgement; never perform an
  acknowledgement round trip for every delivery inside the subscription deadline.
  Periodic Ingestion.catch_up calls remain mandatory when notifications are quiet.
  """
  alias EmailJanitor.{Inbox, Gmail.Ingestion, Google.PubSub.Delivery, Store.Scope}

  def poll_once({pubsub, config}, router) when is_function(router, 1) do
    try do
      with {:ok, deliveries} when is_list(deliveries) <- pubsub.pull(config),
           true <- length(deliveries) <= 100 do
        {stored, failed} =
          Enum.reduce(deliveries, {[], 0}, fn delivery, {stored, failed} ->
            case record(delivery, router) do
              :ok -> {[delivery | stored], failed}
              _ -> {stored, failed + 1}
            end
          end)

        recorded = length(stored)

        acknowledged =
          if stored != [] and acknowledge(pubsub, config, Enum.reverse(stored)) == :ok,
            do: recorded,
            else: 0

        {:ok,
         %{
           recorded: recorded,
           acknowledged: acknowledged,
           failed: failed + recorded - acknowledged
         }}
      else
        _ -> {:error, :notification_unavailable}
      end
    rescue
      _ -> {:error, :notification_unavailable}
    catch
      _, _ -> {:error, :notification_unavailable}
    end
  end

  defp record(%Delivery{} = delivery, router) do
    with {:ok, %Scope{} = scope, %Inbox{address: address} = inbox} <-
           router.(delivery.email_address),
         true <- address == delivery.email_address,
         {:ok, :ok} <- Ingestion.record_signal(scope, inbox, delivery.history_id) do
      :ok
    else
      _ -> {:error, :signal_not_stored}
    end
  rescue
    _ -> {:error, :signal_not_stored}
  catch
    _, _ -> {:error, :signal_not_stored}
  end

  defp record(_, _), do: {:error, :signal_not_stored}

  defp acknowledge(pubsub, config, deliveries) do
    case pubsub.acknowledge(config, deliveries) do
      :ok -> :ok
      _ -> {:error, :acknowledgement_failed}
    end
  rescue
    _ -> {:error, :acknowledgement_failed}
  catch
    _, _ -> {:error, :acknowledgement_failed}
  end
end
