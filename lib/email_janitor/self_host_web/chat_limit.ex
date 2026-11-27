defmodule EmailJanitor.SelfHostWeb.ChatLimit do
  @moduledoc "Bounded ephemeral conversations. HTTP caller death does not release provider capacity."
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def run(fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__.Server, {:run, :owner, fun}, :infinity)
  catch
    _, _ -> {:error, :unavailable}
  end

  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: __MODULE__.Owner},
        {Task.Supervisor, name: __MODULE__.Tasks, max_children: 2},
        __MODULE__.Server
      ],
      strategy: :one_for_one
    )
  end
end

defmodule EmailJanitor.SelfHostWeb.ChatLimit.Server do
  @moduledoc false
  use GenServer
  alias EmailJanitor.SelfHostWeb.ChatLimit

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_), do: {:ok, %{buckets: %{}, slots: %{}}}

  @impl true
  def handle_call({:run, key, fun}, from, state) do
    now = System.monotonic_time(:second)
    buckets = Map.reject(state.buckets, fn {_, {deadline, _}} -> deadline <= now end)
    {deadline, count} = Map.get(buckets, key, {now + 60, 0})

    cond do
      Enum.any?(state.slots, fn {_, slot} -> slot.key == key end) or
        Registry.lookup(ChatLimit.Owner, key) != [] or map_size(state.slots) >= 2 ->
        {:reply, {:error, :busy}, %{state | buckets: buckets}}

      count >= 5 ->
        {:reply, {:error, :rate_limited}, %{state | buckets: buckets}}

      true ->
        case start_work(key, fun) do
          {:ok, task} ->
            slot = %{key: key, pid: task.pid, from: from}

            {:noreply,
             %{
               state
               | buckets: Map.put(buckets, key, {deadline, count + 1}),
                 slots: Map.put(state.slots, task.ref, slot)
             }}

          _ ->
            {:reply, {:error, :busy}, %{state | buckets: buckets}}
        end
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.slots, ref) do
      {nil, _} ->
        {:noreply, state}

      {slot, slots} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(slot.from, result)
        {:noreply, %{state | slots: slots}}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state.slots, ref) do
      {nil, _} ->
        {:noreply, state}

      {slot, slots} ->
        GenServer.reply(slot.from, {:error, :unavailable})
        {:noreply, %{state | slots: slots}}
    end
  end

  defp start_work(key, fun) do
    {:ok, Task.Supervisor.async_nolink(ChatLimit.Tasks, fn -> perform(key, fun) end)}
  rescue
    _ -> {:error, :busy}
  catch
    _, _ -> {:error, :busy}
  end

  defp perform(key, fun) do
    # Catch before a task crash could cause Logger to inspect an exception with
    # the transient message/provider payload. Only fixed failures leave the task.
    try do
      case Registry.register(ChatLimit.Owner, key, nil) do
        {:ok, _} -> fun.()
        _ -> {:error, :busy}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      _, _ -> {:error, :unavailable}
    after
      Registry.unregister(ChatLimit.Owner, key)
    end
  end
end
