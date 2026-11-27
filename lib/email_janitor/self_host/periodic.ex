defmodule EmailJanitor.SelfHost.Periodic do
  @moduledoc "One bounded task per persistent host job; state contains only a continuation marker."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :tick)

    {:ok,
     %{
       run: Keyword.fetch!(opts, :run),
       timeout: Keyword.fetch!(opts, :timeout_ms),
       metadata: nil,
       task: nil,
       deadline: nil
     }}
  end

  @impl true
  def handle_info(:tick, %{task: nil} = state) do
    runner = state.run
    metadata = state.metadata

    task =
      Task.Supervisor.async(EmailJanitor.ExecutorSupervisor, fn ->
        try do
          runner.(metadata)
        rescue
          _ -> :failed
        catch
          _, _ -> :failed
        end
      end)

    deadline = Process.send_after(self(), {:deadline, task.ref}, state.timeout)
    {:noreply, %{state | task: task, deadline: deadline}}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.deadline)
    {metadata, delay} = next(result, state.metadata)
    Process.send_after(self(), :tick, delay)
    {:noreply, %{state | task: nil, deadline: nil, metadata: metadata}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state) do
    Process.cancel_timer(state.deadline)
    Process.send_after(self(), :tick, 60_000)
    {:noreply, %{state | task: nil, deadline: nil}}
  end

  def handle_info({:deadline, ref}, %{task: %{ref: ref} = task} = state) do
    Task.Supervisor.terminate_child(EmailJanitor.ExecutorSupervisor, task.pid)
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :tick, 60_000)
    {:noreply, %{state | task: nil, deadline: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %{pid: pid}}) do
    Task.Supervisor.terminate_child(EmailJanitor.ExecutorSupervisor, pid)
    :ok
  end

  def terminate(_, _), do: :ok

  defp next({:next, metadata, delay}, previous)
       when is_integer(delay) and delay in 0..60_000 do
    if is_nil(metadata) or (is_binary(metadata) and byte_size(metadata) <= 1024),
      do: {metadata, delay},
      else: {previous, 60_000}
  end

  defp next(_, previous), do: {previous, 60_000}
end
