defmodule EmailJanitor.Gmail.NotificationWorker do
  @moduledoc """
  One bounded pull/record/ack step, suitable for a host's supervised scheduler.

  A trusted host router maps a verified notification email to its storage scope
  and Inbox. It must never derive scopes from request/model parameters. Unknown
  routes, uninitialized connections and failed commits remain unacknowledged.
  The host may explicitly return {:ignore, :disconnected} only after verifying
  that exact address belongs to its deliberately disconnected stored inbox. That
  route acknowledges without creating a checkpoint or scheduling cleanup.
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
        {ackable, recorded, ignored, failed} =
          Enum.reduce(deliveries, {[], 0, 0, 0}, fn delivery,
                                                    {ackable, recorded, ignored, failed} ->
            case record(delivery, router) do
              :recorded -> {[delivery | ackable], recorded + 1, ignored, failed}
              :ignored -> {[delivery | ackable], recorded, ignored + 1, failed}
              _ -> {ackable, recorded, ignored, failed + 1}
            end
          end)

        accepted = length(ackable)

        acknowledged =
          if ackable != [] and acknowledge(pubsub, config, Enum.reverse(ackable)) == :ok,
            do: accepted,
            else: 0

        {:ok,
         %{
           recorded: recorded,
           ignored: ignored,
           acknowledged: acknowledged,
           failed: failed + accepted - acknowledged
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
    case router.(delivery.email_address) do
      # Only a trusted host's exact database-owned disconnected identity may use
      # this explicit no-work route. Unknown addresses must remain errors.
      {:ignore, :disconnected} ->
        :ignored

      {:ok, %Scope{} = scope, %Inbox{address: address} = inbox}
      when address == delivery.email_address ->
        case Ingestion.record_signal(scope, inbox, delivery.history_id) do
          {:ok, :ok} -> :recorded
          _ -> {:error, :signal_not_stored}
        end

      _ ->
        {:error, :signal_not_stored}
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
