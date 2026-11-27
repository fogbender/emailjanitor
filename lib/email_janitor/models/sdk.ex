defmodule EmailJanitor.Models.SDK do
  @moduledoc "Thin ReqLLM adapter: AWS Bedrock self-hosting and Azure SaaS; no custom wire protocol."
  @behaviour EmailJanitor.Classifier
  alias EmailJanitor.{Content, Decision, HTML, Inbox, Message, TargetDecisions}
  alias EmailJanitor.Models.Config
  @external_resource Path.expand("../../../priv/prompts/classify.txt", __DIR__)
  @prompt File.read!(@external_resource)

  def classify(messages, instructions, opts) do
    started = System.monotonic_time()
    result = perform(messages, instructions, opts)

    :telemetry.execute(
      [:email_janitor, :model, :stop],
      %{duration: System.monotonic_time() - started},
      %{status: elem(result, 0)}
    )

    result
  end

  defp perform(messages, instructions, opts) do
    %Config{} = config = Keyword.fetch!(opts, :config)
    %Inbox{} = inbox = Keyword.fetch!(opts, :inbox)

    # SDK debug logging is process-global; fail closed if a host enables it.
    false = ReqLLM.Debug.enabled?()
    # Finch events include raw request bodies/headers. Observer configuration is
    # a host trust boundary: fail closed if ANY Finch handlers are installed.
    [] = :telemetry.list_handlers([:finch])

    if not is_binary(instructions) or byte_size(instructions) > 32_000,
      do: throw(:invalid_content)

    target_ids = Keyword.get(opts, :target_ids)

    if not is_nil(target_ids) and (not is_list(target_ids) or length(target_ids) not in 1..5),
      do: throw(:invalid_content)

    schema = if is_nil(target_ids), do: Decision.schema(), else: TargetDecisions.schema()

    payload = messages |> selected_messages() |> Enum.map(&payload/1) |> Jason.encode!()
    if byte_size(payload) > 96_000, do: throw(:invalid_content)

    system_text =
      @prompt <>
        "\nSELECTED_INBOX_JSON:\n" <>
        Jason.encode!(%{address: inbox.address, relay_addresses: inbox.relay_addresses}) <>
        "\nUSER_PREFERENCES:\n" <>
        instructions <>
        "\nOUTPUT_SCHEMA_JSON:\n" <> Jason.encode!(schema)

    user_text = "UNTRUSTED_EMAIL_JSON:\n" <> payload

    # Bound the entire encoded context, including accumulated preferences and
    # trusted mailbox identity, before the SDK allocates/prepares any request.
    encoded_context =
      Jason.encode!([
        %{role: "system", content: system_text},
        %{role: "user", content: user_text}
      ])

    if byte_size(encoded_context) > 96_000, do: throw(:invalid_content)
    context = [ReqLLM.Context.system(system_text), ReqLLM.Context.user(user_text)]

    options =
      [
        max_tokens: 4096,
        max_retries: 0,
        receive_timeout: 30_000,
        total_timeout: 35_000,
        telemetry: [payloads: :none],
        req_http_options: Keyword.get(opts, :http_options, [])
      ]
      |> optional(:base_url, config.base_url)
      |> optional(:deployment, config.deployment)

    {:ok, credentials} = credentials(config, opts)
    options = Keyword.merge(options, credentials)
    provider = if config.provider == :bedrock, do: :amazon_bedrock, else: :azure

    model = %{provider: provider, id: config.model}
    # ReqLLM does not force structured tools for Nova Micro. Classification has
    # no executable tools, so use its normal text API and validate JSON locally.
    generated = generate(config.provider, model, context, options, schema)

    with {:ok, response} <- generated,
         object =
           if(config.provider == :bedrock,
             do: ReqLLM.Response.text(response),
             else: ReqLLM.Response.object(response)
           ),
         {:ok, _} <- parse(object, target_ids) do
      if is_binary(object), do: Jason.decode(object), else: {:ok, object}
    else
      _ -> {:error, :model_unavailable}
    end
  rescue
    _ -> {:error, :model_unavailable}
  catch
    :throw, reason when reason in [:invalid_html, :invalid_content] ->
      {:keep, :unreadable_content}

    _, _ ->
      {:error, :model_unavailable}
  end

  # ReqLLM 1.31 emits raw request-bearing exceptions even with payloads:none.
  # Use its provider preparation/decoding pipeline unchanged, but strip lifecycle
  # telemetry before any request can run. No global handlers are detached and no
  # provider protocol/authentication is implemented here. Pinned SDK tests attach
  # a real exporter and assert these events cannot leak on any failure path.
  defp parse(object, nil), do: Decision.parse(object)
  defp parse(object, target_ids), do: TargetDecisions.parse(object, target_ids)

  defp generate(provider, model, context, options, schema) do
    # The pinned Converse decoder can log untrusted model text at warning level.
    # Silence only this caller while the SDK prepares, dispatches and decodes;
    # restore its exact prior setting even when the provider raises or throws.
    previous = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    try do
      generate_quietly(provider, model, context, options, schema)
    after
      if is_nil(previous),
        do: Logger.delete_process_level(self()),
        else: Logger.put_process_level(self(), previous)
    end
  end

  defp generate_quietly(provider, model, context, options, schema) do
    deadline = ReqLLM.TimeoutBudget.deadline(options)
    {:ok, resolved} = ReqLLM.model(model)

    {client, operation, options} =
      case provider do
        :bedrock ->
          {ReqLLM.Providers.AmazonBedrock, :chat, Keyword.delete(options, :output_validation)}

        :azure ->
          {:ok, schema} = ReqLLM.Schema.compile(schema)
          {ReqLLM.Providers.Azure, :object, Keyword.put(options, :compiled_schema, schema)}
      end

    with {:ok, options} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             client,
             operation,
             resolved,
             options
           ),
         {:ok, request} <- client.prepare_request(operation, resolved, context, options) do
      key = ReqLLM.Telemetry.request_context_key()

      request = %{
        request
        | private: Map.delete(request.private, key),
          request_steps:
            [janitor_quiet_sdk: &quiet_request/1] ++
              Keyword.delete(request.request_steps, :llm_telemetry_start),
          response_steps: Keyword.delete(request.response_steps, :llm_telemetry_stop),
          error_steps: Keyword.delete(request.error_steps, :llm_telemetry_exception)
      }

      ReqLLM.Runtime.execute_prepared(request, deadline, fn
        %Req.Response{status: status, body: %ReqLLM.Response{} = response}
        when status in 200..299 ->
          {:ok, response}

        _ ->
          {:error, :model_unavailable}
      end)
    end
  end

  # TimeoutBudget runs Req in its own short-lived Task, which does not inherit
  # Logger's caller-local setting. Suppress it before any SDK request/decode step.
  defp quiet_request(request) do
    Logger.put_process_level(self(), :none)
    request
  end

  defp payload(message) do
    %{
      "message_id" => message.id,
      "in_inbox" => Message.in_inbox?(message),
      "cleanup_target" => Message.cleanup_target?(message),
      "from" => header(message, "from"),
      "reply_to" => header(message, "reply-to"),
      "to" => header(message, "to"),
      "cc" => header(message, "cc"),
      "delivered_to" => header(message, "delivered-to"),
      "subject" => header(message, "subject"),
      "original_sender" => header(message, "x-original-sender"),
      "original_from" => header(message, "x-original-from"),
      "text" => text(message)
    }
  end

  defp selected_messages(messages) do
    {actionable, context} =
      messages
      |> Enum.with_index()
      |> Enum.split_with(fn {message, _index} -> Message.cleanup_target?(message) end)

    if length(actionable) > 5, do: throw(:invalid_content)

    (actionable ++ Enum.take(context, -(5 - length(actionable))))
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp header(message, name) do
    case Message.header(message, name) do
      nil -> nil
      value when is_binary(value) -> bounded(value, 4096)
      _ -> throw(:invalid_content)
    end
  end

  defp bounded(value, bytes) do
    prefix = binary_part(value, 0, min(byte_size(value), bytes))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _} -> valid
      _ -> throw(:invalid_content)
    end
  end

  defp text(%Message{body: nil}), do: ""

  defp text(%Message{body: %Content{} = body} = message) do
    type =
      case Message.header(message, "content-type") do
        nil ->
          "text/plain"

        value when is_binary(value) and byte_size(value) <= 4096 ->
          value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

        _ ->
          throw(:invalid_content)
      end

    case type do
      "text/html" ->
        case HTML.readable(body) do
          {:ok, text} -> bounded(Content.read(text), 16_000)
          _ -> throw(:invalid_html)
        end

      "text/plain" ->
        bounded(Content.read(body), 16_000)

      _ ->
        throw(:invalid_content)
    end
  end

  defp credentials(%Config{provider: :azure} = config, _opts),
    do: {:ok, [api_key: Content.read(config.api_key), provider_options: [store: false]]}

  defp credentials(%Config{provider: :bedrock} = config, opts) do
    resolver = Keyword.get(opts, :credential_resolver, &EmailJanitor.Models.AWSRole.fetch/1)

    with {:ok, credentials} <- resolver.(config.region),
         do: {:ok, [provider_options: credentials]}
  end

  defp optional(opts, _, nil), do: opts
  defp optional(opts, key, value), do: Keyword.put(opts, key, value)
end
