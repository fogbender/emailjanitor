defmodule EmailJanitor.Owner do
  @moduledoc """
  Local-runtime death proof for a single-host service. Expiry alone is not fencing.

  Linux host/boot/process-start identity survives BEAM restarts. A different host
  or a still-live different runtime is unknown and cannot be recovered blindly.
  """
  @request_ms 30_000
  @runtime_key {__MODULE__, :runtime}
  @deadline_key {__MODULE__, :execution_deadline}

  @doc "Run one execution in an isolated owner, never the caller's reusable process."
  def run(fun, timeout_ms \\ 60_000) when timeout_ms in 1..60_000 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    task =
      Task.Supervisor.async_nolink(EmailJanitor.ExecutorSupervisor, fn ->
        Process.put(@deadline_key, deadline)

        try do
          fun.()
        rescue
          _ -> {:error, :executor_unavailable}
        catch
          _, _ -> {:error, :executor_unavailable}
        end
      end)

    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :executor_unavailable}
    end
  end

  def capture do
    runtime = runtime()

    Map.merge(runtime, %{
      owner_token: Ecto.UUID.generate(),
      owner_beam_pid: :erlang.term_to_binary(self())
    })
  end

  def owns?(action) do
    action.owner_runtime == runtime().owner_runtime and
      action.owner_beam_pid == :erlang.term_to_binary(self())
  end

  def proof(action) do
    current = runtime()

    cond do
      action.owner_runtime == current.owner_runtime ->
        local_proof(action)

      is_nil(current.owner_host) or is_nil(current.owner_boot) ->
        :unknown

      is_nil(action.owner_host) or is_nil(action.owner_boot) or is_nil(action.owner_os_start) ->
        :unknown

      action.owner_host != current.owner_host ->
        :unknown

      action.owner_boot != current.owner_boot ->
        :dead

      true ->
        case process_start(action.owner_os_pid) do
          {:ok, start} -> if start == action.owner_os_start, do: :unknown, else: :dead
          {:error, :absent} -> :dead
          _ -> :unknown
        end
    end
  end

  @doc "Stop an expired local owner and wait for actual death; never stop remote/unknown runtimes."
  def stop(action) do
    with true <- action.owner_runtime == runtime().owner_runtime,
         {:ok, pid} <- local_pid(action),
         false <- pid == self() do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :dead
      after
        1_000 ->
          Process.demonitor(ref, [:flush])
          :unknown
      end
    else
      _ -> :unknown
    end
  end

  @doc "Bound adapter dispatch by terminating its owner; stranded durable intents recover separately."
  def bounded(fun, timeout_ms \\ @request_ms) when timeout_ms in 1..@request_ms do
    case dispatch_window(timeout_ms) do
      :ok -> bounded_ready(fun, timeout_ms)
      error -> error
    end
  end

  @doc "Reserve a complete mutation watchdog window inside the overall execution deadline."
  def dispatch_window(timeout_ms \\ @request_ms) do
    case Process.get(@deadline_key) do
      nil ->
        :ok

      deadline ->
        if deadline - System.monotonic_time(:millisecond) >= timeout_ms + 1000,
          do: :ok,
          else: {:error, :dispatch_window_exhausted}
    end
  end

  defp bounded_ready(fun, timeout_ms) do
    owner = self()
    ref = make_ref()

    {watchdog, watchdog_monitor} =
      spawn_monitor(fn ->
        monitor = Process.monitor(owner)

        receive do
          {:finished, ^ref} -> Process.demonitor(monitor, [:flush])
          {:DOWN, ^monitor, :process, ^owner, _} -> :ok
        after
          timeout_ms -> Process.exit(owner, :kill)
        end
      end)

    try do
      fun.()
    after
      send(watchdog, {:finished, ref})

      receive do
        {:DOWN, ^watchdog_monitor, :process, ^watchdog, _} -> :ok
      after
        1_000 ->
          Process.exit(watchdog, :kill)
          Process.demonitor(watchdog_monitor, [:flush])
      end
    end
  end

  defp runtime do
    case :persistent_term.get(@runtime_key, nil) do
      nil ->
        pid = System.pid()
        host = read_id("/etc/machine-id")
        boot = read_id("/proc/sys/kernel/random/boot_id")

        start =
          case process_start(pid) do
            {:ok, value} -> value
            _ -> nil
          end

        identity =
          :erlang.term_to_binary({host, boot, pid, start, :erlang.system_info(:start_time)})

        value = %{
          owner_host: host,
          owner_boot: boot,
          owner_os_pid: pid,
          owner_os_start: start,
          owner_runtime: :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)
        }

        :persistent_term.put(@runtime_key, value)
        value

      value ->
        value
    end
  end

  defp local_proof(action) do
    case local_pid(action) do
      {:ok, pid} -> if Process.alive?(pid), do: :alive, else: :dead
      _ -> :unknown
    end
  end

  defp local_pid(action) do
    case :erlang.binary_to_term(action.owner_beam_pid, [:safe]) do
      pid when is_pid(pid) -> if node(pid) == node(), do: {:ok, pid}, else: :error
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp read_id(path) do
    case File.read(path) do
      {:ok, value} ->
        case String.trim(value) do
          "" -> nil
          value -> :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
        end

      _ ->
        nil
    end
  end

  defp process_start(pid) when is_binary(pid) do
    if Regex.match?(~r/\A[0-9]+\z/, pid) do
      case File.read("/proc/" <> pid <> "/stat") do
        {:ok, stat} ->
          case Regex.run(~r/\A\d+ \(.*\) (.*)\z/s, String.trim(stat)) do
            [_, rest] ->
              case Enum.at(String.split(rest), 19) do
                nil -> {:error, :invalid}
                start -> {:ok, start}
              end

            _ ->
              {:error, :invalid}
          end

        {:error, :enoent} ->
          {:error, :absent}

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  end

  defp process_start(_), do: {:error, :invalid}
end
