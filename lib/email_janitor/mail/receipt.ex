defmodule EmailJanitor.Mail.Receipt do
  @moduledoc """
  Whitelisted SES S3-action receipt metadata. Construct only from the restricted
  SQS queue pulled by SDK.poll/1; parsing arbitrary JSON does not authenticate it.
  SES verdicts and SMTP envelope describe transport, never prove a human's identity.
  MIME headers, commonHeaders and notification content are deliberately discarded.
  """
  alias EmailJanitor.{Address, Content}
  alias EmailJanitor.Mail.{Config, SDK}
  @enforce_keys [:id, :key, :received_at, :envelope_from, :recipients, :verdicts]
  defstruct [:id, :key, :received_at, :envelope_from, :recipients, :verdicts]

  def parse(%Config{} = config, %Content{} = json) do
    with raw when is_binary(raw) and byte_size(raw) <= 262_144 <- Content.read(json),
         {:ok, %{"notificationType" => "Received", "mail" => mail, "receipt" => receipt} = data} <-
           Jason.decode(raw),
         false <- Map.has_key?(data, "content"),
         %{"messageId" => id, "source" => source} <- mail,
         true <- is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,256}\z/, id),
         {:ok, source} <- envelope(source),
         %{"timestamp" => timestamp, "recipients" => recipients, "action" => action} <- receipt,
         {:ok, at, _} <- DateTime.from_iso8601(timestamp),
         true <- DateTime.compare(at, DateTime.add(DateTime.utc_now(), 300)) != :gt,
         {:ok, recipients} <- recipients(recipients),
         %{"type" => "S3", "topicArn" => topic, "bucketName" => bucket, "objectKey" => key} <-
           action,
         true <- topic == config.topic_arn and bucket == config.bucket,
         true <- key == id,
         object_key = "incoming/" <> id,
         true <- SDK.valid_key?(object_key),
         {:ok, verdicts} <- verdicts(receipt) do
      {:ok,
       %__MODULE__{
         id: id,
         key: object_key,
         received_at: at,
         envelope_from: source,
         recipients: recipients,
         verdicts: verdicts
       }}
    else
      _ -> {:error, :invalid_ses_receipt}
    end
  rescue
    _ -> {:error, :invalid_ses_receipt}
  catch
    _, _ -> {:error, :invalid_ses_receipt}
  end

  defp envelope(""), do: {:ok, ""}
  defp envelope(value), do: Address.normalize(value)

  defp recipients(values) when is_list(values) and length(values) in 1..50 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Address.normalize(value) do
        {:ok, address} -> {:cont, {:ok, [address | acc]}}
        _ -> {:halt, {:error, :invalid_recipient}}
      end
    end)
  end

  defp recipients(_), do: {:error, :invalid_recipient}

  defp verdicts(receipt) do
    Enum.reduce_while(
      ["spamVerdict", "virusVerdict", "spfVerdict", "dkimVerdict", "dmarcVerdict"],
      {:ok, %{}},
      fn key, {:ok, acc} ->
        case get_in(receipt, [key, "status"]) do
          value when value in ["PASS", "FAIL", "GRAY", "PROCESSING_FAILED"] ->
            {:cont, {:ok, Map.put(acc, key, value)}}

          _ ->
            {:halt, {:error, :invalid_verdict}}
        end
      end
    )
  end
end
