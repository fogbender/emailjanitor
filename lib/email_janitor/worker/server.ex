defmodule EmailJanitor.Worker.Server do
  @moduledoc """
  Bounded local scheduler for trusted metadata inbox references. List/resolve are
  bounded host database/config operations, never model tools. Returned configs
  must bind authorization/reporting to that connection; no ambient active user.
  Durable arrival/receipt/defer state makes scheduler restarts resume safely.
  """
  use GenServer
  alias EmailJanitor.Gmail.Parser
  alias EmailJanitor.Worker

  @good [
    :idle,
    :done,
    :kept,
    :blocked,
    :skipped,
    :deferred,
    :unresolved,
    :existing,
    :settlement_pending
  ]
  @derive {Inspect, only: [:max_concurrency, :interval_ms]}
  defstruct [
    :list,
    :resolve,
    :step,
    :supervisor,
    :max_concurrency,
    :interval_ms,
    :timeout_ms,
    :timer,
    entries: %{},
    running: %{}
  ]

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def wake(server), do: GenServer.cast(server, :wake)

  @impl true
  def init(options) do
    list = options[:list]
    resolve = options[:resolve]
    maximum = Keyword.get(options, :max_concurrency, 2)
    interval = Keyword.get(options, :interval_ms, 30_000)
    timeout = Keyword.get(options, :timeout_ms, 300_000)
    step = Keyword.get(options, :step, &Worker.step/1)

    if is_function(list, 0) and is_function(resolve, 1) and is_function(step, 1) and
         is_integer(maximum) and maximum in 1..8 and is_integer(interval) and
         interval in 10..300_000 and
         is_integer(timeout) and timeout in 10..300_000 do
      {:ok, supervisor} = Task.Supervisor.start_link()
      send(self(), :tick)

      {:ok,
       %__MODULE__{
         list: list,
         resolve: resolve,
         step: step,
         supervisor: supervisor,
         max_concurrency: maximum,
         interval_ms: interval,
         timeout_ms: timeout
       }}
    else
      {:stop, :invalid_worker_server}
    end
  end

  @impl true
  def handle_cast(:wake, state) do
    now = System.monotonic_time(:millisecond)
    entries = Map.new(state.entries, fn {key, entry} -> {key, %{entry | due: now}} end)
    send(self(), :tick)
    {:noreply, %{state | entries: entries}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :tick, state.interval_ms)
    state = %{state | timer: timer}
    now = System.monotonic_time(:millisecond)

    entries =
      case list_refs(state.list) do
        {:ok, refs} ->
          Map.new(refs, fn key -> {key, Map.get(state.entries, key, %{due: now, attempts: 0})} end)

        _ ->
          state.entries
      end

    {:noreply, dispatch(%{state | entries: entries}, now)}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{key: key, timer: timer}, running} ->
        Process.cancel_timer(timer)
        Process.demonitor(ref, [:flush])
        state = finish(%{state | running: running}, key, outcome)
        {:noreply, dispatch(state, System.monotonic_time(:millisecond))}
    end
  end

  def handle_info({:worker_timeout, ref}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{task: task, key: key}, running} ->
        Task.shutdown(task, :brutal_kill)
        state = finish(%{state | running: running}, key, :failed)
        {:noreply, dispatch(state, System.monotonic_time(:millisecond))}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{key: key, timer: timer}, running} ->
        Process.cancel_timer(timer)
        state = finish(%{state | running: running}, key, :failed)
        {:noreply, dispatch(state, System.monotonic_time(:millisecond))}
    end
  end

  defp dispatch(state, now) do
    busy = MapSet.new(Enum.map(state.running, fn {_, value} -> value.key end))

    selected =
      state.entries
      |> Enum.reject(fn {key, value} -> value.due > now or MapSet.member?(busy, key) end)
      |> Enum.sort_by(fn {key, value} -> {value.due, key} end)
      |> Enum.take(max(0, state.max_concurrency - map_size(state.running)))

    Enum.reduce(selected, state, fn {key, _}, state ->
      resolver = state.resolve
      step = state.step
      task = Task.Supervisor.async_nolink(state.supervisor, fn -> run(resolver, step, key) end)
      timer = Process.send_after(self(), {:worker_timeout, task.ref}, state.timeout_ms)
      %{state | running: Map.put(state.running, task.ref, %{task: task, key: key, timer: timer})}
    end)
  end

  defp finish(state, key, outcome) do
    case Map.get(state.entries, key) do
      nil ->
        state

      entry ->
        attempts = if outcome == :failed, do: min(entry.attempts + 1, 8), else: 0

        delay =
          cond do
            outcome == :more -> 100
            outcome == :failed -> min(state.interval_ms * Integer.pow(2, attempts), 300_000)
            true -> state.interval_ms
          end

        %{
          state
          | entries:
              Map.put(state.entries, key, %{
                due: System.monotonic_time(:millisecond) + delay,
                attempts: attempts
              })
        }
    end
  end

  defp run(resolve, step, key) do
    try do
      case resolve.(key) do
        {:ok, %Worker.Config{} = config} ->
          case step.(config) do
            {:ok, %{status: status, more?: more}} when status in @good and is_boolean(more) ->
              if more, do: :more, else: :ok

            _ ->
              :failed
          end

        _ ->
          :failed
      end
    rescue
      _ -> :failed
    catch
      _, _ -> :failed
    end
  end

  defp list_refs(list) do
    try do
      case list.() do
        {:ok, refs} when is_list(refs) and length(refs) <= 10_000 ->
          if Enum.all?(refs, &Parser.valid_id?/1), do: {:ok, Enum.uniq(refs)}, else: :error

        _ ->
          :error
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end
end
