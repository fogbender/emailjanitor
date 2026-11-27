defmodule EmailJanitor.PubSubTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Google.PubSub}
  alias PubSub.{Config, Delivery}
  @subscription "projects/emailjanitor-test/subscriptions/mailbox-changes"

  defp config(resolver \\ fn -> {:ok, Content.new("SERVICE_TOKEN_SENTINEL")} end) do
    {:ok, config} = Config.new(@subscription, resolver, adapter: Tesla.Mock)
    config
  end

  defp received(data \\ %{"emailAddress" => "Owner@Acme.com", "historyId" => "102"}) do
    %{
      "ackId" => "ACK_SENTINEL",
      "message" => %{
        "messageId" => "pubsub-not-gmail-id",
        "data" => Base.encode64(Jason.encode!(data))
      }
    }
  end

  test "generated SDK pull uses only configured subscription, bearer and bounded count" do
    Tesla.Mock.mock(fn env ->
      assert env.method == :post

      assert URI.decode(env.url) ==
               "https://pubsub.googleapis.com/v1/" <> @subscription <> ":pull"

      assert {"authorization", "Bearer SERVICE_TOKEN_SENTINEL"} in env.headers
      assert Jason.decode!(env.body) == %{"maxMessages" => 20}
      assert env.query == []
      Tesla.Mock.json(%{"receivedMessages" => [received()]})
    end)

    assert {:ok, [%Delivery{} = delivery]} = PubSub.pull(config(), 20)
    assert delivery.email_address == "owner@acme.com"
    assert delivery.history_id == "102"
    assert delivery.message_id == "pubsub-not-gmail-id"
    assert Content.read(delivery.ack_id) == "ACK_SENTINEL"
    refute inspect(delivery) =~ "ACK_SENTINEL"
    refute Jason.encode!(delivery) =~ "ACK_SENTINEL"
  end

  test "pull does not acknowledge and ack sends exact opaque IDs only" do
    owner = self()

    Tesla.Mock.mock(fn env ->
      if String.ends_with?(env.url, ":pull") do
        Tesla.Mock.json(%{"receivedMessages" => [received()]})
      else
        send(owner, :ack_sent)
        assert String.ends_with?(URI.decode(env.url), @subscription <> ":acknowledge")
        assert Jason.decode!(env.body) == %{"ackIds" => ["ACK_SENTINEL"]}
        Tesla.Mock.json(%{})
      end
    end)

    assert {:ok, [delivery]} = PubSub.pull(config())
    refute_received :ack_sent
    assert :ok = PubSub.acknowledge(config(), [delivery])
    assert_received :ack_sent
  end

  test "empty pulls work and malformed counts or subscriptions never request credentials" do
    Tesla.Mock.mock(fn _ -> Tesla.Mock.json(%{}) end)
    assert {:ok, []} = PubSub.pull(config())
    owner = self()

    connection =
      config(fn ->
        send(owner, :resolved)
        {:ok, "token"}
      end)

    for count <- [0, 101, nil, "100"] do
      assert {:error, :invalid_notification} = PubSub.pull(connection, count)
    end

    refute_received :resolved

    for name <- [
          nil,
          "mailbox-changes",
          "projects/../../subscriptions/x",
          @subscription <> "?evil=1"
        ] do
      assert {:error, :invalid_subscription} = Config.new(name, fn -> {:ok, "token"} end)
    end
  end

  test "malformed and oversized signals cannot become Gmail IDs or leak data" do
    for data <- [
          %{"emailAddress" => "owner@acme.com", "historyId" => "broken"},
          %{"emailAddress" => "not-an-address", "historyId" => "102"},
          %{
            "emailAddress" => "owner@acme.com",
            "historyId" => "102",
            "body" => "PRIVATE_BODY_SENTINEL"
          },
          [],
          String.duplicate("PRIVATE_BODY_SENTINEL", 500)
        ] do
      Tesla.Mock.mock(fn _ -> Tesla.Mock.json(%{"receivedMessages" => [received(data)]}) end)
      log = capture_log(fn -> assert {:error, :invalid_notification} = PubSub.pull(config()) end)
      refute log =~ "PRIVATE_BODY_SENTINEL"
    end

    for invalid <- [%{"ackId" => "ack"}, put_in(received(), ["message", "data"], "not-base64!")] do
      Tesla.Mock.mock(fn _ -> Tesla.Mock.json(%{"receivedMessages" => [invalid]}) end)
      assert {:error, :invalid_notification} = PubSub.pull(config())
    end
  end

  test "acks cannot cross subscriptions, repeat IDs or accept arbitrary IDs" do
    Tesla.Mock.mock(fn _ -> Tesla.Mock.json(%{"receivedMessages" => [received()]}) end)
    assert {:ok, [delivery]} = PubSub.pull(config())
    owner = self()

    connection =
      config(fn ->
        send(owner, :resolved)
        {:ok, "token"}
      end)

    for deliveries <- [
          [%{delivery | subscription: @subscription <> "-other"}],
          [delivery, delivery],
          ["ACK_SENTINEL"],
          []
        ] do
      assert {:error, :invalid_acknowledgement} = PubSub.acknowledge(connection, deliveries)
    end

    refute_received :resolved
  end

  test "provider failures and resolver exceptions have fixed errors, no retry or logs" do
    owner = self()

    for {status, reason} <- [
          {401, :authorization_required},
          {403, :forbidden},
          {429, :rate_limited},
          {503, :pubsub_unavailable}
        ] do
      Tesla.Mock.mock(fn _ ->
        send(owner, :request)
        Tesla.Mock.json(%{"error" => "PROVIDER_SECRET_SENTINEL"}, status: status)
      end)

      log = capture_log(fn -> assert {:error, ^reason} = PubSub.pull(config()) end)
      assert_received :request
      refute_received :request
      refute log =~ "SENTINEL"
    end

    assert {:error, :pubsub_unavailable} = PubSub.pull(config(fn -> raise "SECRET_SENTINEL" end))
    refute inspect(config()) =~ "SERVICE_TOKEN_SENTINEL"
  end

  test "Finch observers block service token resolution and pull/ack HTTP" do
    owner = self()

    connection =
      config(fn ->
        send(owner, :resolved)
        {:ok, "token"}
      end)

    id = {__MODULE__, make_ref()}
    assert :ok = :telemetry.attach(id, [:finch, :request, :start], &__MODULE__.observe/4, owner)
    on_exit(fn -> :telemetry.detach(id) end)

    Tesla.Mock.mock(fn _ ->
      send(owner, :request)
      Tesla.Mock.json(%{})
    end)

    assert {:error, :pubsub_unavailable} = PubSub.pull(connection)

    delivery = %Delivery{
      subscription: @subscription,
      ack_id: Content.new("ack"),
      message_id: "pubsub-id",
      email_address: "owner@acme.com",
      history_id: "102"
    }

    assert {:error, :pubsub_unavailable} = PubSub.acknowledge(connection, [delivery])
    refute_received :resolved
    refute_received :request
    refute_received :observed
  end

  def observe(_event, _measurements, _metadata, owner), do: send(owner, :observed)
end
