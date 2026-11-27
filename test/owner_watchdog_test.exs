defmodule EmailJanitor.OwnerWatchdogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmailJanitor.Owner

  test "caller death kills only its isolated owner and prevents later side effects" do
    observer = self()

    unrelated =
      Task.Supervisor.async_nolink(EmailJanitor.ExecutorSupervisor, fn ->
        receive do
          :finish -> :unrelated_completed
        end
      end)

    caller =
      spawn(fn ->
        Owner.run(
          fn ->
            send(observer, {:owned, self()})

            receive do
              :finish -> send(observer, :side_effect_after_death)
            end
          end,
          5_000
        )
      end)

    assert_receive {:owned, owner}, 5_000
    monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
    send(owner, :finish)
    refute_received :side_effect_after_death
    assert Process.alive?(unrelated.pid)
    send(unrelated.pid, :finish)
    assert Task.await(unrelated, 5_000) == :unrelated_completed
  end

  test "the budget expires even when its waiting caller cannot run its timeout" do
    observer = self()

    caller =
      spawn(fn ->
        result =
          Owner.run(
            fn ->
              send(observer, {:owned, self()})

              receive do
                :never -> :unexpected
              end
            end,
            500
          )

        send(observer, {:result, result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:owned, owner}, 5_000
    monitor = Process.monitor(owner)
    :erlang.suspend_process(caller)

    try do
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
      assert Process.alive?(caller)
    after
      if Process.alive?(caller), do: :erlang.resume_process(caller)
    end

    assert_receive {:result, {:error, :executor_unavailable}}, 5_000
  end

  test "nested owners inherit the minimum budget and cascade parent death" do
    observer = self()

    caller =
      spawn(fn ->
        Owner.workflow(
          fn ->
            send(observer, {:workflow_owner, self()})

            Owner.run(
              fn ->
                send(observer, {:nested_owner, self(), Owner.dispatch_window(2_000)})

                receive do
                  :never -> :unexpected
                end
              end,
              60_000
            )
          end,
          1_000
        )
      end)

    assert_receive {:workflow_owner, workflow}, 5_000
    assert_receive {:nested_owner, nested, {:error, :dispatch_window_exhausted}}, 5_000
    workflow_monitor = Process.monitor(workflow)
    nested_monitor = Process.monitor(nested)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^workflow_monitor, :process, ^workflow, _}, 5_000
    assert_receive {:DOWN, ^nested_monitor, :process, ^nested, _}, 5_000
  end

  test "success stays factual and failures expose neither callback text nor exceptions" do
    assert Owner.run(fn -> {:ok, :completed} end) == {:ok, :completed}

    log =
      capture_log(fn ->
        assert Owner.run(fn -> raise "PRIVATE_OWNER_BODY_SENTINEL" end) ==
                 {:error, :executor_unavailable}

        assert Owner.workflow(fn -> throw("PRIVATE_OWNER_BODY_SENTINEL") end) ==
                 {:error, :executor_unavailable}
      end)

    refute log =~ "PRIVATE_OWNER_BODY_SENTINEL"
  end
end
