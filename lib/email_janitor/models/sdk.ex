defmodule EmailJanitor.Models.SDK do
  @moduledoc "Thin ReqLLM adapter for Azure, OpenAI and Anthropic. No CLI-account authentication or custom wire protocol."
  @behaviour EmailJanitor.Classifier
  alias EmailJanitor.{Content, Decision, HTML, Message}
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
    %Config{} = config = Keyword.fetch!(opts, :config)

    context = [
      ReqLLM.Context.system(@prompt <> "\nUSER_PREFERENCES:\n" <> instructions),
      ReqLLM.Context.user(
        "UNTRUSTED_EMAIL_JSON:\n" <> Jason.encode!(Enum.map(Enum.take(messages, -5), &payload/1))
      )
    ]

    options =
      [
        api_key: Content.read(config.api_key),
        max_tokens: 256,
        receive_timeout: 30_000,
        total_timeout: 35_000,
        telemetry: [payloads: :none],
        output_validation: :strict,
        req_http_options: Keyword.merge(Keyword.get(opts, :http_options, []), retry: false)
      ]
      |> optional(:base_url, config.base_url)
      |> optional(:deployment, config.deployment)

    case ReqLLM.generate_object(
           %{provider: config.provider, id: config.model},
           context,
           @schema,
           options
         ) do
      {:ok, response} ->
        object = ReqLLM.Response.object(response)

        case Decision.parse(object) do
          {:ok, _} -> {:ok, object}
          _ -> {:error, :invalid_decision}
        end

      _ ->
        {:error, :model_unavailable}
    end
  rescue
    _ -> {:error, :model_unavailable}
  catch
    _, _ -> {:error, :model_unavailable}
  end

  defp payload(message) do
    %{
      "from" => Message.header(message, "from"),
      "reply_to" => Message.header(message, "reply-to"),
      "subject" => Message.header(message, "subject"),
      "original_sender" => Message.header(message, "x-original-sender"),
      "original_from" => Message.header(message, "x-original-from"),
      "text" => text(message)
    }
  end

  defp text(%Message{body: nil}), do: ""

  defp text(%Message{body: %Content{} = body} = message) do
    if String.starts_with?(Message.header(message, "content-type") || "", "text/html") do
      case HTML.readable(body) do
        {:ok, text} -> Content.read(text)
        _ -> ""
      end
    else
      String.slice(Content.read(body), 0, 16_000)
    end
  end

  defp optional(opts, _, nil), do: opts
  defp optional(opts, key, value), do: Keyword.put(opts, key, value)
end
