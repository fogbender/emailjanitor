defmodule EmailJanitor.JobsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ExUnit.CaptureLog
  alias EmailJanitor.{Jobs, TestRepo}
  alias EmailJanitor.Jobs.Worker
  @name EmailJanitor.JobsTest.Oban
  @prefix "ej_jobs_test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp start_jobs(tasks, oban \\ []) do
    opts = [
      name: @name,
      repo: TestRepo,
      prefix: @prefix,
      tasks: tasks,
      oban: Keyword.merge([testing: :manual], oban)
    ]

    start_supervised!({Jobs, opts})
  end

  defp definition(run, opts \\ []), do: Map.merge(%{run: run, timeout_ms: 5_000}, Map.new(opts))
  defp rows, do: TestRepo.all(from(j in Oban.Job, order_by: j.id), prefix: @prefix, log: false)
  defp one, do: List.last(rows())
  defp drain, do: Oban.drain_queue(@name, queue: :mail, with_scheduled: true, with_safety: false)

  test "an enqueue-only web role neither seeds nor wakes persistent work on boot" do
    tasks = %{"web_role" => definition(fn _ -> flunk("web cannot execute background work") end)}
    start_jobs(tasks)
    job = one()
    args = %{job.args | "wake" => true, "repair" => true, "failures" => 2}
    scheduled_at = DateTime.add(DateTime.utc_now(), 120)

    TestRepo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      [set: [args: args, state: "scheduled", scheduled_at: scheduled_at]],
      prefix: @prefix,
      log: false
    )

    assert :ok = stop_supervised({Jobs, @name})

    start_supervised!(
      {Jobs,
       [
         name: @name,
         repo: TestRepo,
         prefix: @prefix,
         tasks: tasks,
         seed: false,
         oban: [testing: :manual, queues: false, plugins: false]
       ]}
    )

    assert [persisted] = rows()
    assert persisted.id == job.id
    assert persisted.args == args
    assert persisted.scheduled_at == scheduled_at
    assert persisted.state == "scheduled"
    assert {:ok, new} = Jobs.enqueue(@name, "web_role", "new-inbox-epoch")
    assert new.state == "available"
    assert length(rows()) == 2
    refute new.id == job.id
  end

  test "boot seeds one job and preserves continuation and failure backoff across restarts" do
    observer = self()

    tasks = %{
      "spool" =>
        definition(fn marker ->
          send(observer, {:marker, marker, Jobs.failure_count()})
          if is_nil(marker), do: {:next, "incoming/page2", 0}, else: {:retry, 120_000}
        end)
    }

    start_jobs(tasks)
    assert %{snoozed: 1} = drain()
    assert_receive {:marker, nil, 0}
    assert %{snoozed: 1} = drain()
    assert_receive {:marker, "incoming/page2", 0}
    before = one()
    assert before.args["failures"] == 1
    assert :ok = stop_supervised({Jobs, @name})
    start_jobs(tasks)
    assert [after_restart] = rows()
    assert after_restart.id == before.id
    assert after_restart.args == before.args
    assert after_restart.scheduled_at == before.scheduled_at
    assert {:ok, %{id: id, conflict?: true}} = Jobs.enqueue(@name, "spool")
    assert id == before.id
  end

  test "ordinary wake preserves retries; an explicit repair wakes only its selected key" do
    start_jobs(%{"cleanup" => definition(fn _ -> {:retry, 120_000} end, seed?: false)})
    {:ok, a} = Jobs.enqueue(@name, "cleanup", "inbox-a:epoch1")
    {:ok, b} = Jobs.enqueue(@name, "cleanup", "inbox-b:epoch1")
    assert %{snoozed: 2} = drain()
    [before_a, before_b] = rows()
    assert :ok = Jobs.wake(@name, "cleanup", a.args["key"])
    assert Enum.map(rows(), & &1.scheduled_at) == [before_a.scheduled_at, before_b.scheduled_at]
    assert :ok = Jobs.wake(@name, "cleanup", a.args["key"], repair?: true)
    [after_a, after_b] = rows()
    assert after_a.state == "available"
    refute after_a.args["repair"]
    assert after_a.args["failures"] == 0
    assert after_b.id == b.id
    assert after_b.scheduled_at == before_b.scheduled_at
    assert after_b.args == before_b.args
  end

  test "reconcile cancels obsolete account generations without disturbing current work" do
    start_jobs(%{"cleanup" => definition(fn _ -> :done end, seed?: false)})
    {:ok, old} = Jobs.enqueue(@name, "cleanup", "inbox:old-epoch")
    {:ok, current} = Jobs.enqueue(@name, "cleanup", "inbox:new-epoch")
    assert :ok = Jobs.reconcile_keys(@name, "cleanup", [current.args["key"]])
    [old_row, current_row] = rows()
    assert old_row.id == old.id and old_row.state == "cancelled"
    assert current_row.id == current.id and current_row.state == "available"
    assert :ok = Jobs.cancel(@name, "cleanup", current.args["key"])
    assert one().state == "cancelled"
  end

  test "failures, invalid continuations and raw exception text never enter jobs or logs" do
    secret = "PRIVATE_EMAIL_BODY_DO_NOT_RETAIN"
    observer = self()

    start_jobs(%{
      "unsafe" =>
        definition(fn _ ->
          send(observer, {:config_is_runtime_only, secret})
          raise secret
        end)
    })

    log = capture_log(fn -> assert %{snoozed: 1} = drain() end)
    assert_received {:config_is_runtime_only, ^secret}
    row = one()
    refute inspect(row) =~ secret
    refute log =~ secret
    assert row.errors == []
    assert row.args["failures"] == 1
    assert {:error, :invalid_job} = Jobs.enqueue(@name, "unsafe", String.duplicate("x", 1_025))
    assert {:error, :invalid_job} = Jobs.enqueue(@name, "unsafe", %{body: secret})
  end

  for stop <- [:executor_death, :deadline] do
    test "#{stop} stops both the job owner and its nested provider owner" do
      observer = self()
      timeout = if unquote(stop) == :deadline, do: 100, else: 5_000

      start_jobs(%{
        "bounded" =>
          definition(
            fn _ ->
              EmailJanitor.Owner.run(
                fn ->
                  send(observer, {:nested_owner, self()})

                  receive do
                    :never -> :ok
                  end
                end,
                30_000
              )
            end,
            timeout_ms: timeout
          )
      })

      job = %{one() | conf: Oban.config(@name)}
      executor = spawn(fn -> send(observer, {:finished, Worker.perform(job)}) end)
      assert_receive {:nested_owner, owner}, 3_000
      monitor = Process.monitor(owner)
      if unquote(stop) == :executor_death, do: Process.exit(executor, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 3_000
      if unquote(stop) == :deadline, do: assert_receive({:finished, {:snooze, 60}}, 3_000)
    end
  end

  test "real Oban queues enforce concurrency and cancellation kills nested provider work" do
    observer = self()

    start_jobs(
      %{
        "cleanup" =>
          definition(
            fn marker ->
              EmailJanitor.Owner.run(
                fn ->
                  send(observer, {:started, marker, self()})

                  receive do
                    :release -> :done
                  end
                end,
                30_000
              )
            end,
            seed?: false
          )
      },
      testing: :disabled,
      queues: [mail: 2],
      peer: {Oban.Peers.Isolated, []},
      lifeline: false,
      pruner: false
    )

    for key <- ["a", "b", "c"], do: assert({:ok, _} = Jobs.enqueue(@name, "cleanup", key))
    assert_receive {:started, first, first_owner}, 3_000
    assert_receive {:started, second, second_owner}, 3_000
    refute first == second
    refute_receive {:started, _, _}, 100
    monitor = Process.monitor(first_owner)
    assert :ok = Jobs.cancel(@name, "cleanup", first)
    assert_receive {:DOWN, ^monitor, :process, ^first_owner, _}, 3_000
    assert_receive {:started, third, third_owner}, 3_000
    assert third not in [first, second]
    send(second_owner, :release)
    send(third_owner, :release)
    await(fn -> Enum.count(rows(), &(&1.state == "completed")) == 2 end)
    assert Enum.count(rows(), &(&1.state == "cancelled")) == 1
  end

  test "a process restart rescues an orphaned executing job through Oban Lifeline" do
    observer = self()

    tasks = %{
      "recovery" =>
        definition(fn marker ->
          send(observer, {:rescued, marker})
          {:next, "checkpoint", 60_000}
        end)
    }

    start_jobs(tasks)
    job = one()
    assert :ok = stop_supervised({Jobs, @name})
    past = DateTime.add(DateTime.utc_now(), -3_600, :second)

    TestRepo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      [set: [state: "executing", attempted_at: past, attempt: 25]],
      prefix: @prefix,
      log: false
    )

    start_jobs(tasks,
      testing: :disabled,
      queues: [mail: 1],
      peer: {Oban.Peers.Isolated, []},
      lifeline: [interval: 10, rescue_after: 100],
      pruner: false
    )

    assert_receive {:rescued, nil}, 3_000
    await(fn -> one().state == "scheduled" end)
    assert one().args["metadata"] == "checkpoint"
    assert length(rows()) == 1
  end

  defp await(fun, attempts \\ 100)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await(fun, attempts - 1)
        )
  end

  test "a repair between checkpoint and Oban acknowledgement escapes the old failure delay" do
    start_jobs(%{"late_wake" => definition(fn _ -> {:retry, 120_000} end)})
    attempted_at = DateTime.utc_now()
    job = %{one() | conf: Oban.config(@name), attempted_at: attempted_at, attempt: 1}

    TestRepo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      [set: [state: "executing", attempted_at: attempted_at, attempt: 1]],
      prefix: @prefix,
      log: false
    )

    assert {:snooze, 120} = Worker.perform(job)
    assert :ok = Jobs.wake(@name, "late_wake", "late_wake", repair?: true)
    assert one().state == "executing"
    assert :ok = Oban.Engine.snooze_job(job.conf, job, 120)
    assert one().state == "scheduled"
    :telemetry.execute([:oban, :job, :stop], %{}, %{state: :snoozed, job: job})
    assert one().state == "available"
    refute one().args["repair"]
    assert one().args["failures"] == 0
    # Simulate process death after the acknowledgement but before the telemetry
    # handler. The durable pending wake is applied during the next host boot.
    assert :ok = stop_supervised({Jobs, @name})

    TestRepo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      [
        set: [
          state: "scheduled",
          scheduled_at: DateTime.add(DateTime.utc_now(), 120),
          args: %{one().args | "wake" => true, "repair" => true, "failures" => 1}
        ]
      ],
      prefix: @prefix,
      log: false
    )

    start_jobs(%{"late_wake" => definition(fn _ -> {:retry, 120_000} end)})
    assert one().state == "available"
    assert one().id == job.id
  end

  test "an ordinary signal cannot erase an executing job's pending authenticated repair" do
    observer = self()

    start_jobs(%{
      "sticky_repair" =>
        definition(fn _ ->
          send(observer, {:running, self()})

          receive do
            :continue -> {:retry, 120_000}
          end
        end)
    })

    job = %{one() | conf: Oban.config(@name)}

    TestRepo.update_all(from(j in Oban.Job, where: j.id == ^job.id), [set: [state: "executing"]],
      prefix: @prefix,
      log: false
    )

    executor = Task.async(fn -> Worker.perform(job) end)
    assert_receive {:running, runner}, 3_000
    assert :ok = Jobs.wake(@name, "sticky_repair", "sticky_repair", repair?: true)
    assert :ok = Jobs.wake(@name, "sticky_repair", "sticky_repair")
    assert one().args["repair"]
    send(runner, :continue)
    assert {:snooze, 0} = Task.await(executor)
    assert one().args["failures"] == 0
  end

  test "waking idle work causes one run and keeps the next normal cadence" do
    start_jobs(%{"single_wake" => definition(fn _ -> {:next, nil, 60_000} end)})
    assert :ok = Jobs.wake(@name, "single_wake", "single_wake")
    refute one().args["wake"]
    assert %{snoozed: 1} = drain()
    assert DateTime.diff(one().scheduled_at, DateTime.utc_now()) >= 55
  end

  test "wake received while running is persisted and consumed without losing the cursor" do
    observer = self()

    start_jobs(%{
      "pages" =>
        definition(fn _ ->
          send(observer, {:executing, self()})

          receive do
            :continue -> {:next, "page-two", 60_000}
          end
        end)
    })

    job = %{one() | conf: Oban.config(@name)}

    TestRepo.update_all(from(j in Oban.Job, where: j.id == ^job.id), [set: [state: "executing"]],
      prefix: @prefix,
      log: false
    )

    spawn(fn -> send(observer, {:finished, Worker.perform(job)}) end)
    assert_receive {:executing, runner}, 3_000
    assert :ok = Jobs.wake(@name, "pages", "pages")
    assert one().args["wake"]
    send(runner, :continue)
    assert_receive {:finished, {:snooze, 0}}, 3_000
    assert one().args["metadata"] == "page-two"
    refute one().args["wake"]
  end
end
