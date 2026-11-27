defmodule EmailJanitor.ModelsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Classifier, Decision}
  alias EmailJanitor.Models.{Config, SDK}
  @decision %{"action" => "done", "confidence" => "high", "category" => "cold_outreach"}

  defp config(:azure) do
    {:ok, config} =
      Config.new(:azure, "gpt-4o-mini", "TEST_API_KEY_SENTINEL",
        base_url: "https://janitor-test.openai.azure.com/openai",
        deployment: "janitor-eval"
      )

    config
  end

  defp config(:bedrock) do
    {:ok, config} = Config.new(:bedrock, "amazon.nova-micro-v1:0", nil, region: "us-east-1")
    config
  end

  defp run(provider, messages \\ [message(body: "PRIVATE_BODY_SENTINEL")], box \\ inbox()) do
    credentials = fn "us-east-1" ->
      {:ok,
       [
         region: "us-east-1",
         access_key_id: "TEST_ACCESS_ID",
         secret_access_key: "TEST_SECRET_KEY_SENTINEL",
         session_token: "TEST_SESSION_SENTINEL"
       ]}
    end

    Classifier.propose(
      {SDK,
       [
         config: config(provider),
         credential_resolver: credentials,
         http_options: [plug: {Req.Test, __MODULE__}]
       ]},
      messages,
      "Keep requested customer conversations.",
      box
    )
  end

  defp azure_response(conn, object) do
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

  test "Azure SDK routes through configured deployment and keeps body transient" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "janitor-test.openai.azure.com"
      assert conn.request_path == "/openai/deployments/janitor-eval/chat/completions"
      assert Plug.Conn.get_req_header(conn, "api-key") == ["TEST_API_KEY_SENTINEL"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "PRIVATE_BODY_SENTINEL"
      request = Jason.decode!(body)
      assert request["store"] in [nil, false]
      assert get_in(request, ["tool_choice", "function", "name"]) == "structured_output"
      assert [tool] = request["tools"]
      assert (tool["name"] || get_in(tool, ["function", "name"])) == "structured_output"
      azure_response(conn, @decision)
    end)

    assert {:ok, %Decision{action: :done}} = run(:azure)
  end

  test "Bedrock uses SDK SigV4 and Nova Converse, not an API key" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "bedrock-runtime.us-east-1.amazonaws.com"
      assert conn.request_path == "/model/amazon.nova-micro-v1:0/converse"
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert authorization =~ "AWS4-HMAC-SHA256"
      assert authorization =~ "TEST_ACCESS_ID"
      assert authorization =~ "/us-east-1/bedrock/aws4_request"
      assert authorization =~ ~r/SignedHeaders=[^ ]*x-amz-security-token/
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["TEST_SESSION_SENTINEL"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "PRIVATE_BODY_SENTINEL"
      request = Jason.decode!(body)
      assert request["toolConfig"] in [nil, %{}]
      assert get_in(request, ["inferenceConfig", "maxTokens"]) == 4096

      Req.Test.json(conn, %{
        output: %{
          message: %{
            role: "assistant",
            content: [
              %{text: Jason.encode!(@decision)}
            ]
          }
        },
        stopReason: "end_turn",
        usage: %{inputTokens: 100, outputTokens: 15, totalTokens: 115},
        metrics: %{latencyMs: 1}
      })
    end)

    assert {:ok, %Decision{action: :done}} = run(:bedrock)
  end

  for status <- [400, 429, 500] do
    test "HTTP #{status} sends once and never logs echoed content or secrets" do
      count = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(count, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          unquote(status),
          Jason.encode!(%{error: %{message: "PRIVATE_BODY_SENTINEL", type: "server_error"}})
        )
      end)

      logs = capture_log(fn -> assert {:error, :model_unavailable} = run(:azure) end)
      assert Agent.get(count, & &1) == 1
      refute logs =~ "PRIVATE_BODY_SENTINEL"
      refute logs =~ "TEST_API_KEY_SENTINEL"
    end
  end

  test "transport errors send once and expose no raw request" do
    count = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(count, &(&1 + 1))
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, :model_unavailable} = run(:azure)
    assert Agent.get(count, & &1) == 1
  end

  test "metadata-only application telemetry is safe on failed model calls" do
    pid = self()
    id = "janitor-test-model-events"

    :ok =
      :telemetry.attach(
        id,
        [:email_janitor, :model, :stop],
        fn _, measure, meta, target ->
          send(target, {:safe_event, measure, meta})
        end,
        pid
      )

    on_exit(fn -> :telemetry.detach(id) end)

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{error: %{message: "PRIVATE_BODY_SENTINEL"}}))
    end)

    assert {:error, :model_unavailable} = run(:azure)
    assert_receive {:safe_event, %{duration: duration}, %{status: :error} = meta}
    assert is_integer(duration)
    refute inspect(meta) =~ "PRIVATE_BODY_SENTINEL"
  end

  test "an attached upstream exporter cannot capture lifecycle request data on failures" do
    id = "janitor-test-upstream-events"

    :ok =
      :telemetry.attach_many(
        id,
        ReqLLM.Telemetry.events(),
        fn event, measure, meta, pid ->
          send(pid, {:upstream_event, event, measure, meta})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    for failure <- [:transport, 400, 429, 500], provider <- [:azure, :bedrock] do
      Req.Test.stub(__MODULE__, fn conn ->
        if failure == :transport,
          do: Req.Test.transport_error(conn, :econnrefused),
          else:
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              failure,
              Jason.encode!(%{error: %{message: "PRIVATE_BODY_SENTINEL"}})
            )
      end)

      assert {:error, :model_unavailable} = run(provider)
    end

    refute_receive {:upstream_event, [:req_llm, :request, _], _, _}

    for value <- drain_upstream() do
      refute inspect(value) =~ "PRIVATE_BODY_SENTINEL"
      refute inspect(value) =~ "TEST_API_KEY_SENTINEL"
      refute inspect(value) =~ "TEST_SECRET_KEY_SENTINEL"
    end
  end

  defp drain_upstream do
    receive do
      {:upstream_event, event, measure, meta} -> [{event, measure, meta} | drain_upstream()]
    after
      0 -> []
    end
  end

  test "the selected inbox and recipient context reach the request through Reviewer" do
    alias EmailJanitor.{Inbox, Reviewer}

    for address <- ["owner@first.example.com", "owner@second.example.com"] do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ address
        assert body =~ "recipient@example.com"
        azure_response(conn, @decision)
      end)

      {:ok, box} = Inbox.new("box-" <> address, address)
      value = message(headers: [{"From", "sales@vendor.com"}, {"To", "recipient@example.com"}])

      assert {:ok, _} =
               Reviewer.review(
                 [value],
                 box,
                 MapSet.new(),
                 {SDK, [config: config(:azure), http_options: [plug: {Req.Test, __MODULE__}]]},
                 "Only clean unsolicited offers addressed to this inbox.",
                 1
               )
    end
  end

  test "oversized and deeply nested HTML fails closed before DOM construction or HTTP" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("Oversized HTML must never reach the provider") end)

    for source <- [
          String.duplicate("x", 262_145),
          String.duplicate("<div>", 2500) <> "Pitch" <> String.duplicate("</div>", 2500)
        ] do
      value =
        message(
          headers: [{"From", "sales@vendor.com"}, {"Content-Type", "text/html"}],
          body: source
        )

      assert {:keep, :unreadable_content} = run(:azure, [value])
    end
  end

  test "HTML cleanup is case-insensitive and includes only the last five messages" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute body =~ "OLD_BODY_SENTINEL"
      refute body =~ "SCRIPT_SENTINEL"
      assert body =~ "Visible pitch"
      azure_response(conn, @decision)
    end)

    recent =
      for n <- 1..5,
          do:
            message(
              id: "m#{n}",
              headers: [
                {"From", "sales@vendor.com"},
                {"Content-Type", "Text/HTML; charset=UTF-8"}
              ],
              body: "<script>SCRIPT_SENTINEL</script><p>Visible pitch</p>"
            )

    messages = [message(body: "OLD_BODY_SENTINEL") | recent]
    assert {:ok, %Decision{}} = run(:azure, messages)
  end

  test "contradictory model decisions fail closed" do
    Req.Test.stub(__MODULE__, fn conn ->
      azure_response(conn, %{
        "action" => "done",
        "confidence" => "high",
        "category" => "legitimate"
      })
    end)

    assert {:error, _} = run(:azure)
  end

  test "model dispatch fails closed when a raw HTTP exporter or SDK debug mode is enabled" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("Unsafe observer setup must not dispatch") end)
    id = "janitor-test-finch-exporter"
    :ok = :telemetry.attach(id, [:finch, :queue, :start], fn _, _, _, _ -> :ok end, nil)
    assert {:error, :model_unavailable} = run(:azure)
    :ok = :telemetry.detach(id)

    previous = Application.get_env(:req_llm, :debug)
    Application.put_env(:req_llm, :debug, true)
    on_exit(fn -> Application.put_env(:req_llm, :debug, previous) end)
    assert {:error, :model_unavailable} = run(:azure)
  end

  test "an out-of-enum model response is rejected" do
    Req.Test.stub(__MODULE__, fn conn ->
      azure_response(conn, %{
        "action" => "delete",
        "confidence" => "high",
        "category" => "cold_outreach"
      })
    end)

    assert {:error, :model_unavailable} = run(:azure)
  end

  test "Nova text must be valid constrained JSON, not a tool or prose fallback" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        output: %{message: %{role: "assistant", content: [%{text: "PRIVATE_BODY_SENTINEL"}]}},
        stopReason: "end_turn",
        usage: %{inputTokens: 10, outputTokens: 5, totalTokens: 15}
      })
    end)

    assert {:error, :model_unavailable} = run(:bedrock)
  end

  test "config offers only Bedrock self-host and Azure SaaS, and redacts secrets" do
    refute inspect(config(:azure)) =~ "TEST_API_KEY_SENTINEL"
    assert {:error, :invalid_model_config} = Config.new(:openai, "model", "key")
    assert {:error, :invalid_model_config} = Config.new(:anthropic, "model", "key")

    for endpoint <- [
          "http://example.com",
          "https://secret@example.com",
          "https://example.com?key=secret",
          nil
        ] do
      assert {:error, :invalid_model_config} =
               Config.new(:azure, "gpt-4o-mini", "key", base_url: endpoint, deployment: "eval")
    end

    for deployment <- ["eval/other", "eval?x=1", "eval#test"] do
      assert {:error, :invalid_model_config} =
               Config.new(:azure, "gpt-4o-mini", "key",
                 base_url: "https://example.com/openai",
                 deployment: deployment
               )
    end
  end
end
