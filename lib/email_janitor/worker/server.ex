defmodule EmailJanitor.Worker.Server do
  @moduledoc """
  Oban cleanup tasks and a timer-free host wake facade. Only trusted opaque inbox
  references enter jobs; scope, credentials and callbacks are resolved afresh.
  Hosts configure the cleanup queue's concurrency (normally two).
  """
  use GenServer
  alias EmailJanitor.{Jobs, Worker}
  @derive {Inspect, only: [:jobs, :interval_ms, :timeout_ms]}
  defstruct [:jobs, :list, :resolve, :step, :interval_ms, :timeout_ms]

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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def wake(server), do: GenServer.call(server, :wake)
  def wake(server, ref), do: GenServer.call(server, {:repair, ref})

  @impl true
  def init(opts) do
    case configuration(opts) do
      {:ok, config} -> {:ok, config}
      error -> {:stop, elem(error, 1)}
    end
  end

  @impl true
  def handle_call(:wake, _from, config), do: {:reply, wake_refs(config, nil), config}
  def handle_call({:repair, ref}, _from, config), do: {:reply, wake_refs(config, ref), config}

  def tasks(opts) do
    {:ok, config} = configuration(opts)

    %{
      "cleanup_discovery" => %{
        run: fn _ -> discover(config) end,
        timeout_ms: 30_000,
        queue: :discovery
      },
      "cleanup" => %{
        run: fn ref -> run_ref(config, ref) end,
        timeout_ms: config.timeout_ms,
        queue: :cleanup,
        seed?: false
      }
    }
  end

  defp configuration(opts) do
    config = %__MODULE__{
      jobs: opts[:jobs],
      list: opts[:list],
      resolve: opts[:resolve],
      step: Keyword.get(opts, :step, &Worker.step/1),
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      timeout_ms: Keyword.get(opts, :timeout_ms, 300_000)
    }

    if not is_nil(config.jobs) and is_function(config.list, 0) and
         is_function(config.resolve, 1) and is_function(config.step, 1) and
         is_integer(config.interval_ms) and config.interval_ms in 10..300_000 and
         is_integer(config.timeout_ms) and config.timeout_ms in 10..300_000,
       do: {:ok, config},
       else: {:error, :invalid_worker_server}
  end

  defp discover(config) do
    with {:ok, refs} <- refs(config),
         :ok <- Jobs.reconcile_keys(config.jobs, "cleanup", refs),
         :ok <- enqueue_refs(config, refs) do
      {:next, nil, config.interval_ms}
    else
      _ -> retry(config)
    end
  rescue
    _ -> retry(config)
  catch
    _, _ -> retry(config)
  end

  defp wake_refs(config, selected) do
    with {:ok, refs} <- refs(config),
         true <- is_nil(selected) or selected in refs,
         :ok <- Jobs.reconcile_keys(config.jobs, "cleanup", refs) do
      chosen = if is_nil(selected), do: refs, else: [selected]

      Enum.reduce_while(chosen, :ok, fn ref, _ ->
        with {:ok, _} <- Jobs.enqueue(config.jobs, "cleanup", ref),
             :ok <- Jobs.wake(config.jobs, "cleanup", ref, repair?: not is_nil(selected)) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, :worker_unavailable}}
        end
      end)
    else
      false -> :ok
      _ -> {:error, :worker_unavailable}
    end
  rescue
    _ -> {:error, :worker_unavailable}
  catch
    _, _ -> {:error, :worker_unavailable}
  end

  defp refs(config) do
    case config.list.() do
      {:ok, refs} when is_list(refs) and length(refs) <= 10_000 ->
        if Enum.all?(refs, &valid_ref?/1),
          do: {:ok, Enum.uniq(refs)},
          else: {:error, :worker_unavailable}

      _ ->
        {:error, :worker_unavailable}
    end
  end

  defp enqueue_refs(config, refs) do
    Enum.reduce_while(refs, :ok, fn ref, _ ->
      case Jobs.enqueue(config.jobs, "cleanup", ref) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :worker_unavailable}}
      end
    end)
  end

  defp run_ref(config, ref) do
    # Re-check membership before resolving an old scheduled reference. Removing a
    # connection never makes persisted job metadata an authority to use it.
    with true <- valid_ref?(ref),
         {:ok, refs} <- refs(config) do
      if ref in refs do
        with {:ok, %Worker.Config{} = current} <- config.resolve.(ref),
             {:ok, %{status: status, more?: more?}} when status in @good and is_boolean(more?) <-
               config.step.(current) do
          {:next, ref, if(more?, do: 100, else: config.interval_ms)}
        else
          _ -> retry(config)
        end
      else
        :done
      end
    else
      _ -> retry(config)
    end
  rescue
    _ -> retry(config)
  catch
    _, _ -> retry(config)
  end

  defp retry(config),
    do:
      {:retry,
       min(config.interval_ms * Integer.pow(2, min(Jobs.failure_count() + 1, 8)), 300_000)}

  defp valid_ref?(ref),
    do: is_binary(ref) and byte_size(ref) in 1..256 and String.valid?(ref)
end
