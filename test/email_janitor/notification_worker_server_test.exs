defmodule EmailJanitor.NotificationWorkerServerTest do
  use ExUnit.Case, async: false
  import EmailJanitor.TestScheduler
  alias EmailJanitor.Gmail.NotificationWorker.Server
  alias EmailJanitor.Jobs

  test "one actual Oban pull runs and partial recorded results wake cleanup while failures back off" do
    observer = self()

    tasks =
      Server.tasks(
        poll: fn ->
          send(observer, {:polling, self()})
          receive do: (:complete -> :ok)
          {:ok, %{recorded: 1, acknowledged: 0, failed: 1}}
        end,
        wake: fn -> send(observer, :wake) end,
        interval_ms: 5_000,
        timeout_ms: 5_000
      )

    start_tasks(tasks)
    assert_receive {:polling, task}, 3_000
    assert {:ok, %{conflict?: true}} = Jobs.enqueue(jobs(), "gmail_notifications")
    refute_receive {:polling, _}, 100
    refute_received :wake
    send(task, :complete)
    assert_receive :wake, 3_000
    await(fn -> hd(rows("gmail_notifications")).args["failures"] == 1 end)
    refute_receive {:polling, _}, 150
  end

  test "timed out pulls release their queue and keep durable retry state" do
    observer = self()

    start_tasks(
      Server.tasks(
        poll: fn ->
          send(observer, {:polling, self()})
          receive do: (:never -> :ok)
        end,
        interval_ms: 1_000,
        timeout_ms: 100
      )
    )

    assert_receive {:polling, task}, 3_000
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 3_000
    await(fn -> hd(rows("gmail_notifications")).args["failures"] == 1 end)
    refute_receive {:polling, _}, 100
  end

  test "raw poll exceptions remain out of Oban storage and logs" do
    import ExUnit.CaptureLog
    observer = self()

    logs =
      capture_log(fn ->
        start_tasks(
          Server.tasks(
            poll: fn ->
              send(observer, :called)
              raise "PRIVATE_NOTIFICATION_TOKEN"
            end,
            wake: fn -> send(observer, :wake) end,
            interval_ms: 5_000
          )
        )

        assert_receive :called, 3_000
        await(fn -> hd(rows("gmail_notifications")).args["failures"] == 1 end)
        refute_receive :wake, 50
        refute inspect(rows("gmail_notifications")) =~ "PRIVATE_NOTIFICATION_TOKEN"
      end)

    refute logs =~ "PRIVATE_NOTIFICATION_TOKEN"
  end

  test "acknowledged deliberate disconnections do not wake workers" do
    observer = self()

    start_tasks(
      Server.tasks(
        poll: fn ->
          send(observer, :polled)
          {:ok, %{recorded: 0, ignored: 1, acknowledged: 1, failed: 0}}
        end,
        wake: fn -> send(observer, :incorrect_wake) end,
        interval_ms: 5_000
      )
    )

    assert_receive :polled, 3_000
    await(fn -> hd(rows("gmail_notifications")).state == "scheduled" end)
    refute_receive :incorrect_wake, 100
    assert hd(rows("gmail_notifications")).args["failures"] == 0
  end
end
