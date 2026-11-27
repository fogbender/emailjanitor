defmodule EmailJanitor.IngestionBatchTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.{Content, Fixtures, Reconciliation}
  alias EmailJanitor.Gmail.{Config, HistoryBatch, SDK}
  alias EmailJanitor.Store.Action

  defp options do
    {:ok, config} =
      Config.new(Fixtures.inbox(), fn -> {:ok, Content.new("TOKEN_SENTINEL")} end,
        adapter: Tesla.Mock,
        max_pages: 1
      )

    [config: config]
  end

  defp mock(history) do
    Tesla.Mock.mock(fn env ->
      assert {"authorization", "Bearer TOKEN_SENTINEL"} in env.headers

      if String.ends_with?(env.url, "/profile"),
        do: Tesla.Mock.json(%{"emailAddress" => "owner@acme.com", "historyId" => "100"}),
        else: history.(env)
    end)
  end

  defp added(id, message),
    do: %{"id" => id, "messagesAdded" => [%{"message" => %{"id" => message}}]}

  test "closed records checkpoint incrementally without weakening reconciliation evidence" do
    mock(fn env ->
      assert env.query[:pageToken] == nil
      assert env.query[:maxResults] == 500

      response =
        case env.query[:startHistoryId] do
          "100" ->
            %{
              "historyId" => "105",
              "history" => [added("101", "message-1"), added("102", "message-2")],
              "nextPageToken" => "more"
            }

          "102" ->
            %{"historyId" => "106", "history" => [added("103", "message-3")]}
        end

      Tesla.Mock.json(response)
    end)

    assert {:ok,
            %HistoryBatch{
              from_id: "100",
              through_id: "102",
              more?: true,
              added_message_ids: ["message-1", "message-2"]
            } = first} = SDK.ingestion_batch("inbox-1", "100", options())

    refute Map.has_key?(first, :complete?)

    assert {:error, :incomplete_history} =
             Reconciliation.resolve(%Action{history_id: "100", message_ids: ["message-1"]}, first)

    assert {:ok,
            %HistoryBatch{
              from_id: "102",
              through_id: "106",
              more?: false,
              added_message_ids: ["message-3"]
            }} = SDK.ingestion_batch("inbox-1", first.through_id, options())
  end

  test "a single bounded response can contain more than ten thousand added IDs" do
    ids = Enum.map(1..10_001, &"message-#{&1}")

    mock(fn _ ->
      Tesla.Mock.json(%{
        "historyId" => "101",
        "history" => [
          %{"id" => "101", "messagesAdded" => Enum.map(ids, &%{"message" => %{"id" => &1}})}
        ]
      })
    end)

    assert {:ok, %HistoryBatch{through_id: "101", more?: false, added_message_ids: parsed}} =
             SDK.ingestion_batch("inbox-1", "100", options())

    assert length(parsed) == length(ids)
    assert MapSet.new(parsed) == MapSet.new(ids)
  end

  test "malformed, unordered and non-progressing records never produce a batch" do
    for response <- [
          %{"historyId" => "105", "history" => [], "nextPageToken" => "more"},
          %{"historyId" => "105", "history" => [added("103", "one"), added("102", "two")]},
          %{"historyId" => "105", "history" => [added("101", "one"), added("101", "two")]},
          %{"historyId" => "105", "history" => [added("100", "one")]},
          %{"historyId" => "105", "history" => [added("106", "one")]},
          %{"historyId" => "105", "history" => [%{"id" => "101", "messagesAdded" => [%{}]}]},
          %{"historyId" => "105", "history" => [], "nextPageToken" => false}
        ] do
      mock(fn _ -> Tesla.Mock.json(response) end)
      assert {:error, :invalid_history} = SDK.ingestion_batch("inbox-1", "100", options())
    end

    mock(fn _ -> Tesla.Mock.json(%{"error" => "PRIVATE_SENTINEL"}, status: 404) end)
    assert {:error, :history_expired} = SDK.ingestion_batch("inbox-1", "100", options())
  end
end
