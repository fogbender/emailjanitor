defmodule EmailJanitor.Models.SDK do
  @moduledoc "Thin ReqLLM adapter: AWS Bedrock self-hosting and Azure SaaS; no custom wire protocol."
  @behaviour EmailJanitor.Classifier
  alias EmailJanitor.{Content, Decision, HTML, Inbox, Message}
  alias EmailJanitor.Models.Config
  @external_resource Path.expand("../../../priv/prompts/classify.txt", __DIR__)
  @prompt File.read!(@external_resource)
  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action", "confidence", "category"],
    "properties" => %{
      "action" => %{"type" => "string", "enum" => ["keep", "done"]},
      "confidence" => %{"type" => "string", "enum" => ["high", "low"]},
      "category" => %{
        "type" => "string",
        "enum" => ["cold_outreach", "legitimate", "uncertain", "user_instruction"]
      }
    }
  }

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

    context = [
      ReqLLM.Context.system(
        @prompt <>
          "\nSELECTED_INBOX_JSON:\n" <>
          Jason.encode!(%{address: inbox.address, relay_addresses: inbox.relay_addresses}) <>
          "\nUSER_PREFERENCES:\n" <> instructions
      ),
      ReqLLM.Context.user(
        "UNTRUSTED_EMAIL_JSON:\n" <> Jason.encode!(Enum.map(Enum.take(messages, -5), &payload/1))
      )
    ]

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
    generated = generate(config.provider, model, context, options)

    with {:ok, response} <- generated,
         object =
           if(config.provider == :bedrock,
             do: ReqLLM.Response.text(response),
             else: ReqLLM.Response.object(response)
           ),
         {:ok, _} <- Decision.parse(object) do
      if is_binary(object), do: Jason.decode(object), else: {:ok, object}
    else
      _ -> {:error, :model_unavailable}
    end
  rescue
    _ -> {:error, :model_unavailable}
  catch
    :throw, :invalid_html -> {:keep, :unreadable_content}
    _, _ -> {:error, :model_unavailable}
  end

  # ReqLLM 1.31 emits raw request-bearing exceptions even with payloads:none.
  # Use its provider preparation/decoding pipeline unchanged, but strip lifecycle
  # telemetry before any request can run. No global handlers are detached and no
  # provider protocol/authentication is implemented here. Pinned SDK tests attach
  # a real exporter and assert these events cannot leak on any failure path.
  defp generate(provider, model, context, options) do
    deadline = ReqLLM.TimeoutBudget.deadline(options)
    {:ok, resolved} = ReqLLM.model(model)

    {client, operation, options} =
      case provider do
        :bedrock ->
          {ReqLLM.Providers.AmazonBedrock, :chat, Keyword.delete(options, :output_validation)}

        :azure ->
          {:ok, schema} = ReqLLM.Schema.compile(@schema)
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
          request_steps: Keyword.delete(request.request_steps, :llm_telemetry_start),
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

  defp payload(message) do
    %{
      "from" => Message.header(message, "from"),
      "reply_to" => Message.header(message, "reply-to"),
      "to" => Message.header(message, "to"),
      "cc" => Message.header(message, "cc"),
      "delivered_to" => Message.header(message, "delivered-to"),
      "subject" => Message.header(message, "subject"),
      "original_sender" => Message.header(message, "x-original-sender"),
      "original_from" => Message.header(message, "x-original-from"),
      "text" => text(message)
    }
  end

  defp text(%Message{body: nil}), do: ""

  defp text(%Message{body: %Content{} = body} = message) do
    type = Message.header(message, "content-type")

    if is_binary(type) and String.starts_with?(String.downcase(type), "text/html") do
      case HTML.readable(body) do
        {:ok, text} -> Content.read(text)
        _ -> throw(:invalid_html)
      end
    else
      String.slice(Content.read(body), 0, 16_000)
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
