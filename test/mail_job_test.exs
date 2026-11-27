defmodule EmailJanitor.MailJobTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.Mail.Job

  test "a continuation drains promptly and killing its server kills the in-flight task" do
    observer = self()

    {:ok, server} =
      Job.start_link(
        timeout_ms: 5_000,
        run: fn
          nil ->
            {:next, "incoming/page2", 0}

          "incoming/page2" ->
            send(observer, {:continuation, self()})

            receive do
              :never -> {:next, nil, 60_000}
            end
        end
      )

    Process.unlink(server)
    assert_receive {:continuation, task}, 5_000
    assert :sys.get_state(server).metadata == "incoming/page2"
    monitor = Process.monitor(task)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5_000
  end

  test "the watchdog kills a stalled task while the server remains recoverable" do
    observer = self()

    {:ok, server} =
      Job.start_link(
        timeout_ms: 500,
        run: fn _ ->
          send(observer, {:running, self()})

          receive do
            :never -> {:next, nil, 60_000}
          end
        end
      )

    assert_receive {:running, task}, 5_000
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5_000
    assert Process.alive?(server)
    assert :sys.get_state(server).task == nil
    GenServer.stop(server)
  end

  for stop <- [:server_death, :deadline] do
    test "#{stop} stops nested Owner work as well as its direct job task" do
      assert_nested_cancellation(unquote(stop))
    end
  end

  defp assert_nested_cancellation(stop) do
    observer = self()

    {:ok, server} =
      Job.start_link(
        timeout_ms: if(stop == :deadline, do: 500, else: 5_000),
        run: fn _ ->
          EmailJanitor.Owner.run(
            fn ->
              send(observer, {:nested_owner, self()})

              receive do
                :never -> :ok
              end
            end,
            30_000
          )
        end
      )

    Process.unlink(server)
    assert_receive {:nested_owner, task}, 5_000
    monitor = Process.monitor(task)
    if stop == :server_death, do: Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5_000
    if stop == :deadline, do: GenServer.stop(server)
  end
end
