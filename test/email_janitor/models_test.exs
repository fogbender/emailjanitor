defmodule EmailJanitor.ModelsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Classifier, Decision}
  alias EmailJanitor.Models.{Config, SDK}

  @decision %{"action" => "done", "confidence" => "high", "category" => "cold_outreach"}

  defp config(provider) do
    opts =
      if provider == :azure,
        do: [base_url: "https://janitor-test.openai.azure.com/openai", deployment: "janitor-eval"],
        else: []

    {:ok, config} =
      Config.new(
        provider,
        if(provider == :anthropic, do: "claude-haiku-4-5", else: "gpt-4o-mini"),
        "TEST_API_KEY_SENTINEL",
        opts
      )

    config
  end

  defp run(provider) do
    Classifier.propose(
      {SDK, [config: config(provider), http_options: [plug: {Req.Test, __MODULE__}]]},
      [message(body: "PRIVATE_BODY_SENTINEL")],
      "Keep requested customer conversations."
    )
  end

  defp openai(conn, object) do
    if String.ends_with?(conn.request_path, "/responses") do
      Req.Test.json(conn, %{
        id: "test-response",
        object: "response",
        status: "completed",
        model: "gpt-4o-mini",
        output: [
          %{
            id: "function-1",
            type: "function_call",
            call_id: "call-1",
            name: "structured_output",
            arguments: Jason.encode!(object),
            status: "completed"
          }
        ],
        usage: %{input_tokens: 100, output_tokens: 15, total_tokens: 115}
      })
    else
      chat_completion(conn, object)
    end
  end

  defp chat_completion(conn, object) do
    Req.Test.json(conn, %{
      id: "test-completion",
      object: "chat.completion",
      created: 1,
      model: "gpt-4o-mini",
      choices: [
        %{
          index: 0,
          finish_reason: "tool_calls",
          message: %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{
                id: "tool-1",
                type: "function",
                function: %{name: "structured_output", arguments: Jason.encode!(object)}
              }
            ]
          }
        }
      ],
      usage: %{prompt_tokens: 100, completion_tokens: 15, total_tokens: 115}
    })
  end

  test "OpenAI uses the SDK's structured output and keeps transient body out of results" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer TEST_API_KEY_SENTINEL"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "PRIVATE_BODY_SENTINEL"
      request = Jason.decode!(body)
      assert [tool] = request["tools"]
      assert (tool["name"] || get_in(tool, ["function", "name"])) == "structured_output"
      openai(conn, @decision)
    end)

    assert {:ok, %Decision{action: :done}} = run(:openai)
  end

  test "Azure SDK routes through the configured deployment with API-key authentication" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "janitor-test.openai.azure.com"
      assert conn.request_path =~ "/deployments/janitor-eval/chat/completions"
      assert Plug.Conn.get_req_header(conn, "api-key") == ["TEST_API_KEY_SENTINEL"]
      openai(conn, @decision)
    end)

    assert {:ok, %Decision{action: :done}} = run(:azure)
  end

  test "Anthropic SDK extracts a structured tool result without executing user tools" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["TEST_API_KEY_SENTINEL"]

      Req.Test.json(conn, %{
        id: "test-message",
        type: "message",
        role: "assistant",
        model: "claude-haiku-4-5",
        content: [%{type: "tool_use", id: "tool-1", name: "structured_output", input: @decision}],
        stop_reason: "tool_use",
        usage: %{input_tokens: 100, output_tokens: 15}
      })
    end)

    assert {:ok, %Decision{action: :done}} = run(:anthropic)
  end

  test "provider failure neither logs echoed email content nor returns raw responses" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        500,
        Jason.encode!(%{error: %{message: "PRIVATE_BODY_SENTINEL", type: "server_error"}})
      )
    end)

    logs = capture_log(fn -> assert {:error, :model_unavailable} = run(:openai) end)
    refute logs =~ "PRIVATE_BODY_SENTINEL"
    refute logs =~ "TEST_API_KEY_SENTINEL"
  end

  test "model config redacts credentials and rejects malformed or insecure Azure endpoints" do
    refute inspect(config(:azure)) =~ "TEST_API_KEY_SENTINEL"

    for endpoint <- [
          "http://example.com",
          "https://secret@example.com",
          "https://example.com?key=secret",
          nil
        ] do
      assert {:error, :invalid_model_config} =
               Config.new(:azure, "gpt-4o-mini", "key", base_url: endpoint, deployment: "eval")
    end
  end
end
