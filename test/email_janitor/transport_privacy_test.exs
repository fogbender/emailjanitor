defmodule EmailJanitor.TransportPrivacyTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, Fixtures, TransportPrivacy}
  alias EmailJanitor.Gmail.{Config, SDK}
  alias EmailJanitor.Google.OAuth

  def observe(event, _measurements, _metadata, owner), do: send(owner, {:observed, event})

  test "preflight rejects all Finch event handlers without removing them" do
    assert :ok = TransportPrivacy.check()
    id = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               id,
               [:finch, :unrelated_pool_metric],
               &__MODULE__.observe/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(id) end)
    assert {:error, :unsafe_http_observers} = TransportPrivacy.check()
    assert Enum.any?(:telemetry.list_handlers([:finch]), &(&1.id == id))
  end

  test "Gmail calls stop before token resolution or HTTP when Finch is observed" do
    owner = self()

    {:ok, config} =
      Config.new(
        Fixtures.inbox(),
        fn ->
          send(owner, :token_resolved)
          {:ok, "TOKEN_SENTINEL"}
        end,
        adapter: Tesla.Mock
      )

    Tesla.Mock.mock(fn _ ->
      send(owner, :gmail_http)
      Tesla.Mock.json(%{"emailAddress" => "owner@acme.com", "historyId" => "100"})
    end)

    attach_request_observer()
    options = [config: config]

    for {operation, arguments} <- [
          {:thread, ["inbox-1", "thread-1", options]},
          {:thread_id, ["inbox-1", "message-1", options]},
          {:history_id, ["inbox-1", options]},
          {:history, ["inbox-1", "100", options]},
          {:contacted, ["inbox-1", ["vendor.com"], options]},
          {:remove_inbox, ["inbox-1", ["message-1"], options]},
          {:prepare_remove_inbox, ["inbox-1", ["message-1"], options]},
          {:watch, ["inbox-1", "projects/emailjanitor-test/topics/changes", options]},
          {:stop_watch, ["inbox-1", options]}
        ] do
      assert {:error, :gmail_unavailable} = apply(SDK, operation, arguments)
    end

    refute_received :token_resolved
    refute_received :gmail_http
    refute_received {:observed, _}
  end

  test "OAuth callback and refresh stop before HTTP when Finch is observed" do
    owner = self()

    {:ok, config} =
      OAuth.Config.new(
        "fixture-client",
        "CLIENT_SECRET_SENTINEL",
        "https://janitor.example/callback"
      )

    config = %{config | http_options: [plug: {Req.Test, __MODULE__}]}
    {:ok, %{session_params: session}} = OAuth.authorize_url(config, :sign_in)

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :oauth_http)
      Req.Test.json(conn, %{"error" => "PRIVATE_ERROR_SENTINEL"})
    end)

    attach_request_observer()

    assert {:error, :authorization_failed} =
             OAuth.callback(config, session, %{
               "state" => session.state,
               "code" => "AUTH_CODE_SENTINEL"
             })

    assert {:error, :refresh_failed} =
             OAuth.refresh(
               config,
               Content.new(
                 Jason.encode!(%{
                   "refresh_token" => "REFRESH_SENTINEL",
                   "scope" => "openid email"
                 })
               )
             )

    refute_received :oauth_http
    refute_received {:observed, _}
  end

  test "a prepared dispatch rechecks observer privacy before the mutating request" do
    owner = self()

    {:ok, config} =
      Config.new(Fixtures.inbox(), fn -> {:ok, "TOKEN_SENTINEL"} end, adapter: Tesla.Mock)

    Tesla.Mock.mock(fn env ->
      if String.ends_with?(env.url, "/profile") do
        Tesla.Mock.json(%{"emailAddress" => "owner@acme.com", "historyId" => "100"})
      else
        send(owner, :mutation_http)
        Tesla.Mock.json(%{})
      end
    end)

    assert {:ok, dispatch} = SDK.prepare_remove_inbox("inbox-1", ["message-1"], config: config)
    attach_request_observer()
    assert {:error, :gmail_unavailable} = dispatch.()
    refute_received :mutation_http
    refute_received {:observed, _}
  end

  defp attach_request_observer do
    id = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach_many(
               id,
               [[:finch, :request, :start], [:finch, :request, :stop]],
               &__MODULE__.observe/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
