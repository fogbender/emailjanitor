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
end
