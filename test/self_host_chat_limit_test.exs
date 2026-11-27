defmodule EmailJanitor.SelfHostWeb.ChatLimitTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmailJanitor.SelfHostWeb.ChatLimit

  setup do
    start_supervised!(ChatLimit)
    :ok
  end

  test "HTTP caller death does not release a live provider task's capacity" do
    observer = self()

    caller =
      spawn(fn ->
        ChatLimit.run(fn ->
          send(observer, {:working, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:working, worker}
    Process.exit(caller, :kill)
    assert {:error, :busy} = ChatLimit.run(fn -> flunk("work remains active") end)
    assert Task.Supervisor.children(ChatLimit.Tasks) == [worker]
    ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert :ok = ChatLimit.run(fn -> :ok end)
  end

  test "restarting the limiter server keeps provider capacity reserved by the independent supervisor" do
    observer = self()

    spawn(fn ->
      ChatLimit.run(fn ->
        send(observer, {:working, self()})

        receive do
          :finish -> :ok
        end
      end)
    end)

    assert_receive {:working, worker}
    old = Process.whereis(ChatLimit.Server)
    Process.exit(old, :kill)

    await(
      fn ->
        case Process.whereis(ChatLimit.Server) do
          nil -> false
          ^old -> false
          _ -> true
        end
      end,
      200
    )

    assert {:error, :busy} = ChatLimit.run(fn -> flunk("old work remains active") end)
    assert Task.Supervisor.children(ChatLimit.Tasks) == [worker]
    ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert :ok = ChatLimit.run(fn -> :ok end)
  end

  test "rate limits bound provider work and raw task errors never reach logs" do
    log =
      capture_log(fn ->
        assert {:error, :unavailable} = ChatLimit.run(fn -> raise "PRIVATE_PROVIDER_SENTINEL" end)
      end)

    refute log =~ "PRIVATE_PROVIDER_SENTINEL"
    for _ <- 1..4, do: assert(:ok == ChatLimit.run(fn -> :ok end))
    assert {:error, :rate_limited} = ChatLimit.run(fn -> flunk("minute budget exhausted") end)
  end

  defp await(_, 0), do: flunk("limiter server did not restart")

  defp await(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(fun, left - 1)
        )
  end
end
