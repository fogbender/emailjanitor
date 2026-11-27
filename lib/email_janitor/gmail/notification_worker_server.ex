defmodule EmailJanitor.Gmail.NotificationWorker.Server do
  @moduledoc """
  One supervised authenticated pull/record/ack task at a time. The host supplies
  the trusted Pub/Sub adapter/config and a bounded database-only address router.
  Pull, durable signal commits and acknowledgement run outside the GenServer.
  Catch-up scheduling is independent, so delayed/dropped signals cannot stall mail.
  """
  use GenServer
  alias EmailJanitor.Gmail.NotificationWorker
  @derive {Inspect, only: [:interval_ms, :timeout_ms]}
  defstruct [:poll, :wake, :supervisor, :interval_ms, :timeout_ms, :timer, :running, attempts: 0]

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl true
  def init(options) do
    source = options[:source]
    router = options[:router]
    poll = Keyword.get(options, :poll, fn -> NotificationWorker.poll_once(source, router) end)
    wake = Keyword.get(options, :wake, fn -> :ok end)
    interval = Keyword.get(options, :interval_ms, 5_000)
    timeout = Keyword.get(options, :timeout_ms, 120_000)

    if is_function(poll, 0) and is_function(wake, 0) and is_integer(interval) and
         interval in 10..300_000 and is_integer(timeout) and timeout in 10..300_000 and
         (Keyword.has_key?(options, :poll) or
            (match?({module, _} when is_atom(module), source) and is_function(router, 1))) do
      {:ok, supervisor} = Task.Supervisor.start_link()
      send(self(), :tick)

      {:ok,
       %__MODULE__{
         poll: poll,
         wake: wake,
         supervisor: supervisor,
         interval_ms: interval,
         timeout_ms: timeout
       }}
    else
      {:stop, :invalid_notification_server}
    end
  end

  @impl true
  def handle_info(:tick, %{running: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    poll = state.poll
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> run(poll) end)
    timer = Process.send_after(self(), {:poll_timeout, task.ref}, state.timeout_ms)
    {:noreply, %{state | running: task, timer: timer}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, result}, %{running: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if result == :recorded, do: wake(state.wake)
    {:noreply, schedule(state, result)}
  end

  def handle_info({:poll_timeout, ref}, %{running: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, schedule(state, :failed)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{running: %Task{ref: ref}} = state),
    do: {:noreply, schedule(state, :failed)}

  def handle_info(_, state), do: {:noreply, state}

  defp schedule(state, outcome) do
    if state.timer, do: Process.cancel_timer(state.timer)
    attempts = if outcome == :failed, do: min(state.attempts + 1, 8), else: 0
    delay = min(state.interval_ms * Integer.pow(2, attempts), 300_000)
    timer = Process.send_after(self(), :tick, delay)
    %{state | running: nil, timer: timer, attempts: attempts}
  end

  defp run(poll) do
    case poll.() do
      {:ok, %{recorded: recorded, failed: failed}}
      when is_integer(recorded) and recorded >= 0 and is_integer(failed) and failed >= 0 ->
        cond do
          recorded > 0 -> :recorded
          failed > 0 -> :failed
          true -> :idle
        end

      _ ->
        :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp wake(callback) do
    callback.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
