defmodule EmailJanitor.NotificationWorkerServerTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Gmail.NotificationWorker.Server

  test "only one pull task runs and wake follows durable recorded results" do
    owner = self()

    server =
      start_supervised!(
        {Server,
         poll: fn ->
           send(owner, {:polling, self()})

           receive do
             :complete -> :ok
           end

           {:ok, %{recorded: 1, acknowledged: 0, failed: 1}}
         end,
         wake: fn -> send(owner, :wake) end,
         interval_ms: 1_000,
         timeout_ms: 5_000}
      )

    assert_receive {:polling, task}, 1_000
    send(server, :tick)
    send(server, :tick)
    refute_receive {:polling, _}, 50
    refute_received :wake
    send(task, :complete)
    assert_receive :wake, 1_000
    refute_receive {:polling, _}, 50
    refute inspect(:sys.get_state(server)) =~ "poll:"
  end

  test "failed or timed out pulls back off and no longer hold a running task" do
    owner = self()

    server =
      start_supervised!(
        {Server,
         poll: fn ->
           send(owner, {:polling, self()})

           receive do
             :complete -> :ok
           end

           {:error, :synthetic}
         end,
         interval_ms: 1_000,
         timeout_ms: 100}
      )

    assert_receive {:polling, task}, 1_000
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, reason}, 1_000
    assert reason in [:killed, :noproc]
    state = :sys.get_state(server)
    assert state.running == nil and state.attempts == 1
    refute_receive {:polling, _}, 100
  end

  test "raw poll exceptions are sanitized and never wake inbox workers" do
    import ExUnit.CaptureLog
    owner = self()

    logs =
      capture_log(fn ->
        server =
          start_supervised!(
            {Server,
             poll: fn ->
               send(owner, :called)
               raise "PRIVATE_NOTIFICATION_TOKEN"
             end,
             wake: fn -> send(owner, :wake) end,
             interval_ms: 1_000}
          )

        assert_receive :called, 1_000
        refute_receive :wake, 50
        state = :sys.get_state(server)
        assert state.attempts == 1 and state.running == nil
      end)

    refute logs =~ "PRIVATE_NOTIFICATION_TOKEN"
  end

  test "acknowledged deliberate disconnections do not wake cleanup workers" do
    owner = self()

    server =
      start_supervised!(
        {Server,
         poll: fn ->
           send(owner, :polled_disconnected)
           {:ok, %{recorded: 0, ignored: 1, acknowledged: 1, failed: 0}}
         end,
         wake: fn -> send(owner, :incorrect_cleanup_wake) end,
         interval_ms: 5_000}
      )

    assert_receive :polled_disconnected, 1_000
    refute_receive :incorrect_cleanup_wake, 100
    assert :sys.get_state(server).attempts == 0
  end
end
