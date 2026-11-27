defmodule EmailJanitor.GmailExecutorTest.Transport do
  @moduledoc false
  def call(env, options), do: options[:handler].(env)
end

defmodule EmailJanitor.GmailExecutorTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures, only: [inbox: 0]
  alias EmailJanitor.{Content, Executor, Reviewer, Store, TestClassifier, TestRepo}
  alias EmailJanitor.Gmail.{Config, Parser, SDK}
  alias EmailJanitor.Store.{Action, Scope}

  test "real SDK account preparation precedes intent and exact mutation follows its fence" do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    box = inbox()
    {:ok, _} = Store.add_inbox(scope, box)
    observer = self()

    raw = %{
      "id" => "message-1",
      "threadId" => "thread-1",
      "internalDate" => "1795708800000",
      "labelIds" => ["INBOX", "UNREAD", "IMPORTANT"],
      "payload" => %{
        "mimeType" => "text/plain",
        "headers" => [%{"name" => "From", "value" => "sales@vendor.com"}],
        "body" => %{"data" => Base.url_encode64("Synthetic cold sales pitch", padding: false)}
      }
    }

    google = Poison.decode!(Jason.encode!(raw), as: %GoogleApi.Gmail.V1.Model.Message{})
    {:ok, message} = Parser.message(google)
    {:ok, proposal} = Reviewer.review([message], box, MapSet.new(), {TestClassifier, []}, "", 1)

    handler = fn env ->
      assert {"authorization", "Bearer SYNTHETIC_TOKEN"} in env.headers
      refute TestRepo.in_transaction?()

      response =
        cond do
          String.ends_with?(env.url, "/profile") ->
            assert [] = TestRepo.all(Action, prefix: scope.prefix)
            Process.sleep(25)
            send(observer, :account_verified_before_intent)
            %{"emailAddress" => box.address, "historyId" => "100"}

          String.ends_with?(env.url, "/threads/thread-1") ->
            %{"id" => "thread-1", "messages" => [raw]}

          String.ends_with?(env.url, "/messages") ->
            %{"messages" => []}

          String.ends_with?(env.url, "/messages/batchModify") ->
            [action] = TestRepo.all(Action, prefix: scope.prefix)
            assert action.state == :intent
            assert %DateTime{} = action.dispatch_started_at
            assert :erlang.binary_to_term(action.owner_beam_pid, [:safe]) == self()

            assert Jason.decode!(env.body) == %{
                     "ids" => ["message-1"],
                     "removeLabelIds" => ["INBOX"]
                   }

            send(observer, :mutation_after_dispatch_fence)
            :empty
        end

      if response == :empty,
        do: {:ok, %Tesla.Env{status: 204, body: ""}},
        else:
          {:ok,
           %Tesla.Env{
             status: 200,
             body: Jason.encode!(response),
             headers: [{"content-type", "application/json"}]
           }}
    end

    resolver = fn ->
      assert [] = TestRepo.all(Action, prefix: scope.prefix)
      refute TestRepo.in_transaction?()
      {:ok, Content.new("SYNTHETIC_TOKEN")}
    end

    {:ok, config} = Config.new(box, resolver, adapter: {__MODULE__.Transport, handler: handler})
    assert {:done, id} = Executor.execute(scope, box, proposal, {SDK, [config: config]})
    assert_received :account_verified_before_intent
    assert_received :mutation_after_dispatch_fence
    assert %Action{state: :done} = Store.get(scope, box.id, id)
  end
end
