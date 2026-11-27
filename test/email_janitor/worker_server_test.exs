defmodule EmailJanitor.WorkerServerTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Worker.{Config, Server}

  defp config(ref) do
    %Config{
      scope: nil,
      inbox: %{EmailJanitor.Fixtures.inbox() | id: ref},
      gmail: {nil, []},
      classifier: {nil, []},
      preferences: fn -> nil end,
      authorize: fn -> :ok end,
      topic: "synthetic"
    }
  end

  test "bounded scheduler never overlaps the same inbox and fills available slots" do
    owner = self()

    step = fn config ->
      send(owner, {:started, config.inbox.id, self()})

      receive do
        :continue -> :ok
      end

      {:ok, %{status: :idle, more?: false}}
    end

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, ["a", "b", "c", "a"]} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: step,
         max_concurrency: 2,
         interval_ms: 1_000,
         timeout_ms: 5_000}
      )

    assert_receive {:started, "a", first}, 1_000
    assert_receive {:started, "b", second}, 1_000
    Server.wake(server)
    refute_receive {:started, _, _}, 50
    send(first, :continue)
    assert_receive {:started, "c", third}, 1_000
    refute_receive {:started, "a", _}, 50
    send(second, :continue)
    send(third, :continue)
    refute inspect(:sys.get_state(server)) =~ "preferences"
  end

  test "a timed-out inbox cannot block another and its next attempt backs off" do
    owner = self()

    step = fn config ->
      send(owner, {:started, config.inbox.id, self()})
      if config.inbox.id == "a", do: receive(do: (:continue -> :ok))
      {:ok, %{status: :idle, more?: false}}
    end

    start_supervised!(
      {Server,
       list: fn -> {:ok, ["a", "b"]} end,
       resolve: fn ref -> {:ok, config(ref)} end,
       step: step,
       max_concurrency: 1,
       interval_ms: 1_000,
       timeout_ms: 200}
    )

    assert_receive {:started, "a", first}, 1_000
    monitor = Process.monitor(first)
    assert_receive {:DOWN, ^monitor, :process, ^first, reason}, 1_000
    assert reason in [:killed, :noproc]
    assert_receive {:started, "b", _}, 500
    refute_receive {:started, "a", _}, 100
  end

  test "resolver failures remain isolated and returned secrets never appear in logs" do
    import ExUnit.CaptureLog
    owner = self()

    logs =
      capture_log(fn ->
        start_supervised!(
          {Server,
           list: fn -> {:ok, ["a", "b"]} end,
           resolve: fn
             "a" -> raise "PRIVATE_RESOLVER_SECRET"
             ref -> {:ok, config(ref)}
           end,
           step: fn cfg ->
             send(owner, {:stepped, cfg.inbox.id})
             {:ok, %{status: :idle, more?: false}}
           end,
           interval_ms: 1_000}
        )

        assert_receive {:stepped, "b"}, 500
        refute_receive {:stepped, "a"}, 50
      end)

    refute logs =~ "PRIVATE_RESOLVER_SECRET"
  end

  test "notification wake does not bypass failure backoff", _ctx do
    owner = self()

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, ["a"]} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: fn _ ->
           send(owner, :attempted)
           {:ok, %{status: :rate_limited, more?: false}}
         end,
         interval_ms: 1_000}
      )

    assert_receive :attempted, 1_000
    # The completion is serialized through this same server before the wake.
    wait_failed(server, 100)
    for _ <- 1..5, do: Server.wake(server)
    refute_receive :attempted, 100
  end

  test "due backlog runs again promptly without waiting the normal poll interval" do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    start_supervised!(
      {Server,
       list: fn -> {:ok, ["a"]} end,
       resolve: fn ref -> {:ok, config(ref)} end,
       step: fn _ ->
         count = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
         send(owner, {:slice, count})
         {:ok, %{status: :done, more?: count == 1}}
       end,
       interval_ms: 5_000}
    )

    assert_receive {:slice, 1}, 1_000
    assert_receive {:slice, 2}, 1_000
    refute_receive {:slice, 3}, 100
  end

  defp wait_failed(_server, 0), do: flunk("step did not enter failure backoff")

  defp wait_failed(server, left) do
    if :sys.get_state(server).entries["a"].attempts > 0 do
      :ok
    else
      Process.sleep(5)
      wait_failed(server, left - 1)
    end
  end
end
