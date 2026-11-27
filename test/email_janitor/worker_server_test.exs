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

  test "notification wake during a successful step coalesces into one immediate followup" do
    owner = self()

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, ["a"]} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: fn _ ->
           send(owner, {:started, self()})
           receive do: (:continue -> :ok)
           {:ok, %{status: :idle, more?: false}}
         end,
         interval_ms: 5_000,
         timeout_ms: 5_000}
      )

    assert_receive {:started, first}, 1_000
    for _ <- 1..3, do: Server.wake(server)
    assert :sys.get_state(server).entries["a"].pending_wake
    refute_receive {:started, _}, 50
    send(first, :continue)
    assert_receive {:started, second}, 1_000
    send(second, :continue)
    refute_receive {:started, _}, 100
  end

  test "notification wake during a failed step preserves backoff and consumes the hint" do
    owner = self()

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, ["a"]} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: fn _ ->
           send(owner, {:started, self()})
           receive do: (:continue -> :ok)
           {:ok, %{status: :rate_limited, more?: false}}
         end,
         interval_ms: 5_000,
         timeout_ms: 5_000}
      )

    assert_receive {:started, first}, 1_000
    Server.wake(server)
    assert :sys.get_state(server).entries["a"].pending_wake
    send(first, :continue)
    wait_failed(server, 100)
    refute Map.get(:sys.get_state(server).entries["a"], :pending_wake, false)
    refute_receive {:started, _}, 100
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

  test "explicit trusted repair resets only the selected reference" do
    owner = self()

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, ["a", "b"]} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: fn cfg ->
           send(owner, {:attempted, cfg.inbox.id})
           {:ok, %{status: :rate_limited, more?: false}}
         end,
         interval_ms: 5_000}
      )

    assert_receive {:attempted, "a"}, 1_000
    assert_receive {:attempted, "b"}, 1_000
    wait_failed_refs(server, ["a", "b"], 100)
    Server.wake(server, "a")
    assert_receive {:attempted, "a"}, 1_000
    refute_receive {:attempted, "b"}, 100
  end

  test "opaque bounded host references are resolved and can be explicitly repaired" do
    owner = self()
    refs = ["group:inbox.1", "owner@example.com", "plain"]

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, refs} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: fn cfg ->
           send(owner, {:opaque, cfg.inbox.id})
           {:ok, %{status: :rate_limited, more?: false}}
         end,
         interval_ms: 5_000}
      )

    for ref <- refs, do: assert_receive({:opaque, ^ref}, 1_000)
    wait_failed_refs(server, refs, 100)
    Server.wake(server, "owner@example.com")
    assert_receive {:opaque, "owner@example.com"}, 1_000
    refute_receive {:opaque, "plain"}, 100
    Server.wake(server, String.duplicate("x", 257))
    refute_receive {:opaque, _}, 100
  end

  test "new explicit wake refreshes the trusted list without reviving another failed inbox" do
    owner = self()
    refs = start_supervised!({Agent, fn -> ["a"] end})

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, Agent.get(refs, & &1)} end,
         resolve: fn ref -> {:ok, config(ref)} end,
         step: fn cfg ->
           send(owner, {:attempted, cfg.inbox.id})
           {:ok, %{status: :rate_limited, more?: false}}
         end,
         interval_ms: 5_000}
      )

    assert_receive {:attempted, "a"}, 1_000
    wait_failed_refs(server, ["a"], 100)
    Agent.update(refs, fn _ -> ["a", "new-ref"] end)
    Server.wake(server, "new-ref")
    assert_receive {:attempted, "new-ref"}, 1_000
    refute_receive {:attempted, "a"}, 100
    Server.wake(server, "not-in-trusted-list")
    refute_receive {:attempted, "not-in-trusted-list"}, 100
  end

  test "explicit repair arriving mid-step runs fresh configuration immediately afterward" do
    owner = self()
    repaired = start_supervised!({Agent, fn -> false end})

    server =
      start_supervised!(
        {Server,
         list: fn -> {:ok, ["a"]} end,
         resolve: fn ref ->
           {:ok,
            %{config(ref) | topic: if(Agent.get(repaired, & &1), do: "repaired", else: "old")}}
         end,
         step: fn cfg ->
           send(owner, {:started_config, cfg.topic, self()})
           if cfg.topic == "old", do: receive(do: (:release -> :ok))
           {:ok, %{status: if(cfg.topic == "old", do: :rate_limited, else: :idle), more?: false}}
         end,
         interval_ms: 5_000,
         timeout_ms: 5_000}
      )

    assert_receive {:started_config, "old", first}, 1_000
    Agent.update(repaired, fn _ -> true end)
    Server.wake(server, "a")
    assert :sys.get_state(server).entries["a"].repair
    send(first, :release)
    assert_receive {:started_config, "repaired", _}, 1_000
  end

  defp wait_failed_refs(_server, _refs, 0), do: flunk("references did not enter backoff")

  defp wait_failed_refs(server, refs, left) do
    state = :sys.get_state(server)

    if Enum.all?(refs, &(state.entries[&1].attempts > 0)) do
      :ok
    else
      Process.sleep(5)
      wait_failed_refs(server, refs, left - 1)
    end
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
