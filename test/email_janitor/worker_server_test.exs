defmodule EmailJanitor.WorkerServerTest do
  use ExUnit.Case, async: false
  import EmailJanitor.TestScheduler
  alias EmailJanitor.Worker.{Config, Server}
  alias EmailJanitor.Jobs

  defp config(ref),
    do: %Config{
      scope: nil,
      inbox: %{EmailJanitor.Fixtures.inbox() | id: ref},
      gmail: {nil, []},
      classifier: {nil, []},
      preferences: fn -> nil end,
      authorize: fn -> :ok end,
      topic: "synthetic"
    }

  defp options(refs, step),
    do: [
      list: fn -> {:ok, refs} end,
      resolve: fn ref -> {:ok, config(ref)} end,
      step: step,
      interval_ms: 5_000,
      timeout_ms: 5_000
    ]

  test "actual Oban queue limits cleanup concurrency and never duplicates a running inbox" do
    observer = self()

    server =
      start_cleanup(
        options(["a", "b", "c", "a"], fn cfg ->
          send(observer, {:started, cfg.inbox.id, self()})
          receive do: (:continue -> :ok)
          {:ok, %{status: :idle, more?: false}}
        end)
      )

    assert_receive {:started, a, first}, 3_000
    assert_receive {:started, b, second}, 3_000
    assert a != b
    assert :ok = Server.wake(server)
    refute_receive {:started, _, _}, 100
    send(first, :continue)
    assert_receive {:started, c, third}, 3_000
    assert c not in [a, b]
    send(second, :continue)
    send(third, :continue)
    refute inspect(:sys.get_state(server)) =~ "preferences"
    assert length(rows("cleanup")) == 3
  end

  test "a timed out inbox releases the bounded slot and preserves durable failure backoff" do
    observer = self()

    opts =
      options(["a", "b"], fn cfg ->
        send(observer, {:started, cfg.inbox.id, self()})
        if cfg.inbox.id == "a", do: receive(do: (:never -> :ok))
        {:ok, %{status: :idle, more?: false}}
      end)
      |> Keyword.merge(timeout_ms: 150, max_concurrency: 1)

    start_cleanup(opts)
    assert_receive {:started, "a", first}, 3_000
    monitor = Process.monitor(first)
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 3_000
    assert_receive {:started, "b", _}, 3_000
    await(fn -> row("a").args["failures"] == 1 end)
    refute_receive {:started, "a", _}, 150
  end

  test "ordinary wake and discovery preserve failed jobs; trusted repair resets only its reference" do
    observer = self()

    server =
      start_cleanup(
        options(["a", "b"], fn cfg ->
          send(observer, {:attempt, cfg.inbox.id})
          {:ok, %{status: :model_unavailable, more?: false}}
        end)
      )

    assert_receive {:attempt, "a"}, 3_000
    assert_receive {:attempt, "b"}, 3_000
    await(fn -> Enum.all?(rows("cleanup"), &(&1.args["failures"] == 1)) end)
    before = row("b")
    for _ <- 1..3, do: Server.wake(server)
    refute_receive {:attempt, _}, 100
    assert row("b").scheduled_at == before.scheduled_at
    assert :ok = Server.wake(server, "a")
    assert_receive {:attempt, "a"}, 3_000
    refute_receive {:attempt, "b"}, 100
    assert row("b").args["failures"] == 1
  end

  for failed? <- [true, false] do
    test "ordinary running wake coalesces and respects failed=#{failed?}" do
      observer = self()

      server =
        start_cleanup(
          options(["a"], fn _ ->
            send(observer, {:started, self()})
            receive do: (:continue -> :ok)
            {:ok, %{status: if(unquote(failed?), do: :rate_limited, else: :idle), more?: false}}
          end)
        )

      assert_receive {:started, first}, 3_000
      for _ <- 1..3, do: Server.wake(server)
      assert row("a").args["wake"]
      send(first, :continue)

      if unquote(failed?) do
        await(fn -> row("a").args["failures"] == 1 end)
        refute_receive {:started, _}, 150
      else
        assert_receive {:started, second}, 3_000
        send(second, :continue)
        refute_receive {:started, _}, 150
      end
    end
  end

  test "explicit repair while running resolves fresh credentials on its immediate next attempt" do
    observer = self()
    repaired = start_supervised!({Agent, fn -> false end})

    opts =
      options(["a"], fn cfg ->
        send(observer, {:started, cfg.topic, self()})
        if cfg.topic == "old", do: receive(do: (:continue -> :ok))
        {:ok, %{status: :rate_limited, more?: false}}
      end)
      |> Keyword.put(:resolve, fn ref ->
        {:ok, %{config(ref) | topic: if(Agent.get(repaired, & &1), do: "repaired", else: "old")}}
      end)

    server = start_cleanup(opts)
    assert_receive {:started, "old", first}, 3_000
    Agent.update(repaired, fn _ -> true end)
    assert :ok = Server.wake(server, "a")
    send(first, :continue)
    assert_receive {:started, "repaired", _}, 3_000
  end

  test "new trusted refs can repair without reviving siblings; removed refs are cancelled" do
    observer = self()
    trusted = start_supervised!({Agent, fn -> ["group:inbox.1"] end})

    opts =
      options([], fn cfg ->
        send(observer, {:attempt, cfg.inbox.id})
        {:ok, %{status: :model_unavailable, more?: false}}
      end)
      |> Keyword.put(:list, fn -> {:ok, Agent.get(trusted, & &1)} end)

    server = start_cleanup(opts)
    assert_receive {:attempt, "group:inbox.1"}, 3_000
    await(fn -> row("group:inbox.1").args["failures"] == 1 end)
    Agent.update(trusted, fn _ -> ["group:inbox.1", "new-ref"] end)
    Server.wake(server, "new-ref")
    assert_receive {:attempt, "new-ref"}, 3_000
    refute_receive {:attempt, "group:inbox.1"}, 150
    Server.wake(server, "not-authorized")
    refute_receive {:attempt, "not-authorized"}, 100
    Agent.update(trusted, fn _ -> ["new-ref"] end)
    Server.wake(server)
    assert row("group:inbox.1").state == "cancelled"
  end

  test "actual jobs survive scheduler restart without resetting failures or leaking runtime secrets" do
    import ExUnit.CaptureLog
    observer = self()

    opts =
      options(["a"], fn _ ->
        send(observer, :attempt)
        raise "PRIVATE_MODEL_BODY_OR_TOKEN"
      end)

    logs =
      capture_log(fn ->
        server = start_cleanup(opts)
        assert_receive :attempt, 3_000
        await(fn -> row("a").args["failures"] == 1 end)
        before = row("a")
        :ok = stop_supervised({Jobs, jobs()})

        start_tasks(Server.tasks(Keyword.put(opts, :jobs, jobs())),
          queues: [cleanup: 2, discovery: 1]
        )

        assert :ok = Server.wake(server)
        assert row("a").args == before.args
        assert row("a").scheduled_at == before.scheduled_at
        refute_receive :attempt, 150
        refute inspect(row("a")) =~ "PRIVATE_MODEL_BODY_OR_TOKEN"
      end)

    refute logs =~ "PRIVATE_MODEL_BODY_OR_TOKEN"
  end

  test "a resolver exception is isolated and neither jobs nor logs retain its secret" do
    import ExUnit.CaptureLog
    observer = self()

    opts =
      options(["a", "b"], fn cfg ->
        send(observer, {:resolved_step, cfg.inbox.id})
        {:ok, %{status: :idle, more?: false}}
      end)
      |> Keyword.put(:resolve, fn
        "a" -> raise "PRIVATE_RESOLVER_CREDENTIAL"
        ref -> {:ok, config(ref)}
      end)

    logs =
      capture_log(fn ->
        start_cleanup(opts)
        assert_receive {:resolved_step, "b"}, 3_000
        await(fn -> row("a").args["failures"] == 1 end)
        refute_receive {:resolved_step, "a"}, 100
        refute inspect(rows("cleanup")) =~ "PRIVATE_RESOLVER_CREDENTIAL"
      end)

    refute logs =~ "PRIVATE_RESOLVER_CREDENTIAL"
  end

  test "pending backlog continues promptly through durable snoozes" do
    observer = self()
    count = start_supervised!({Agent, fn -> 0 end})

    start_cleanup(
      options(["a"], fn _ ->
        n = Agent.get_and_update(count, &{&1 + 1, &1 + 1})
        send(observer, {:slice, n})
        {:ok, %{status: :done, more?: n == 1}}
      end)
    )

    assert_receive {:slice, 1}, 3_000
    assert_receive {:slice, 2}, 3_000
    refute_receive {:slice, 3}, 100
  end
end
