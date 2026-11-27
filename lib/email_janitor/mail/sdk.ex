defmodule EmailJanitor.Mail.SDK do
  @moduledoc "Maintained SES/S3/SQS operations with explicit host credentials and fixed, body-free errors."
  alias EmailJanitor.{Content, Inbox, TransportPrivacy}
  alias EmailJanitor.Mail.{Config, HTTP, Message, Prepared}
  @event [:email_janitor, :private_mail_sdk]

  def prepare(%Config{} = config) do
    with :ok <- privacy(),
         {:ok, credentials} <- config.credentials.(),
         true <- is_list(credentials),
         true <-
           Enum.all?(
             [:access_key_id, :secret_access_key, :security_token],
             &valid_secret?(credentials[&1])
           ) do
      {:ok,
       %Prepared{
         options:
           Keyword.merge(
             Keyword.take(credentials, [:access_key_id, :secret_access_key, :security_token]),
             region: config.region,
             http_client: HTTP,
             http_opts: [test_plug: config.test_plug],
             debug_requests: false,
             json_codec: Jason,
             telemetry_event: @event,
             retries: [max_attempts: 1, client_error_max_attempts: 1],
             refreshable: false,
             scheme: "https://",
             port: 443,
             virtual_host: false,
             bucket_as_host: false,
             telemetry_options: []
           )
       }}
    else
      _ -> {:error, :mail_unavailable}
    end
  rescue
    _ -> {:error, :mail_unavailable}
  catch
    _, _ -> {:error, :mail_unavailable}
  end

  def send(%Config{} = config, %Prepared{} = prepared, %Inbox{} = inbox, %Message{} = message) do
    operation =
      ExAws.SES.send_email(
        %{to: [inbox.address]},
        %{
          subject: %{data: Content.read(message.subject), charset: "UTF-8"},
          body: %{text: %{data: Content.read(message.text), charset: "UTF-8"}}
        },
        config.sender
      )

    case request(operation, prepared) do
      {:ok, %{body: %{message_id: id}}} when is_binary(id) and byte_size(id) in 1..256 ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
          do: {:ok, id},
          else: {:error, :unresolved_delivery}

      _ ->
        {:error, :unresolved_delivery}
    end
  end

  def poll(%Config{} = config) do
    with {:ok, prepared} <- prepare(config),
         {:ok, %{body: %{messages: messages}}} <-
           request(
             ExAws.SQS.receive_message(config.queue_url,
               max_number_of_messages: 1,
               wait_time_seconds: 20
             ),
             prepared
           ) do
      {:ok,
       Enum.map(messages, &%{body: Content.new(&1.body), handle: Content.new(&1.receipt_handle)})}
    else
      _ -> {:error, :mail_unavailable}
    end
  end

  def acknowledge(%Config{} = config, %Content{} = handle) do
    operation(config, ExAws.SQS.delete_message(config.queue_url, Content.read(handle)))
  end

  def fetch(%Config{} = config, key) do
    with true <- valid_key?(key),
         {:ok, %{headers: headers}} <-
           operation(config, ExAws.S3.head_object(config.bucket, key)),
         :ok <- content_length(headers),
         {:ok, %{body: body}} <- operation(config, ExAws.S3.get_object(config.bucket, key), :raw),
         true <- is_binary(body) and byte_size(body) <= 1_048_576 do
      {:ok, Content.new(body)}
    else
      {:error, :mail_too_large} -> {:error, :mail_too_large}
      _ -> {:error, :mail_unavailable}
    end
  end

  defp content_length(headers) do
    value =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(name) == "content-length", do: value
      end)

    case Integer.parse(value || "") do
      {size, ""} when size >= 0 and size <= 1_048_576 -> :ok
      {size, ""} when size > 1_048_576 -> {:error, :mail_too_large}
      _ -> {:error, :mail_unavailable}
    end
  end

  def delete(%Config{} = config, key) do
    if valid_key?(key) do
      case operation(config, ExAws.S3.delete_object(config.bucket, key)) do
        {:ok, _} -> :ok
        _ -> {:error, :mail_unavailable}
      end
    else
      {:error, :invalid_spool_reference}
    end
  end

  def list(%Config{} = config, marker \\ nil) do
    opts = [prefix: "incoming/", max_keys: 100] ++ if(marker, do: [marker: marker], else: [])

    case operation(config, ExAws.S3.list_objects(config.bucket, opts)) do
      {:ok, %{body: %{contents: objects} = body}} ->
        next =
          if body.is_truncated in [true, "true"] do
            if body.next_marker in [nil, ""], do: List.last(objects).key, else: body.next_marker
          end

        {:ok, objects, next}

      _ ->
        {:error, :mail_unavailable}
    end
  end

  def valid_key?(key),
    do: is_binary(key) and Regex.match?(~r/\Aincoming\/[A-Za-z0-9_-]{1,256}\z/, key)

  defp operation(config, operation, format \\ :xml) do
    with {:ok, prepared} <- prepare(config), do: request(operation, prepared, format)
  end

  defp request(operation, prepared, format \\ :xml) do
    with :ok <- privacy() do
      options = prepared.options
      region = options[:region]
      service = if match?(%ExAws.Operation.S3{}, operation), do: :s3, else: operation.service

      host =
        case service do
          :ses -> "email.#{region}.amazonaws.com"
          :s3 -> "s3.#{region}.amazonaws.com"
          :sqs -> "sqs.#{region}.amazonaws.com"
        end

      options =
        options
        |> Keyword.put(:host, host)
        |> Keyword.update!(:http_opts, &Keyword.put(&1, :format, format))

      case quietly(fn -> ExAws.request(operation, options) end) do
        {:ok, _} = result -> result
        {:error, :mail_response_too_large} -> {:error, :mail_too_large}
        _ -> {:error, :mail_unavailable}
      end
    end
  rescue
    _ -> {:error, :mail_unavailable}
  catch
    _, _ -> {:error, :mail_unavailable}
  end

  defp quietly(fun) do
    previous = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Logger.delete_process_level(self()),
        else: Logger.put_process_level(self(), previous)
    end
  end

  defp privacy do
    with :ok <- TransportPrivacy.check(),
         [] <- :telemetry.list_handlers(@event),
         [] <- :telemetry.list_handlers([:ex_aws]),
         false <- Application.get_env(:ex_aws, :debug_requests, false) do
      :ok
    else
      _ -> {:error, :unsafe_http_observers}
    end
  end

  defp valid_secret?(value), do: is_binary(value) and byte_size(value) in 1..4096
end
