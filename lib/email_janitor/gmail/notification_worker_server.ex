defmodule EmailJanitor.Gmail.NotificationWorker.Server do
  @moduledoc """
  One durable Oban pull task. Hosts assign the notification queue concurrency one;
  authenticated pull, scoped signal commits and acknowledgements retain their
  domain fences. Configuration and routing callbacks never enter job arguments.
  """
  alias EmailJanitor.{Gmail.NotificationWorker, Jobs}

  def tasks(opts) do
    source = opts[:source]
    router = opts[:router]
    poll = Keyword.get(opts, :poll, fn -> NotificationWorker.poll_once(source, router) end)
    wake = Keyword.get(opts, :wake, fn -> :ok end)
    interval = Keyword.get(opts, :interval_ms, 5_000)
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    true =
      is_function(poll, 0) and is_function(wake, 0) and is_integer(interval) and
        interval in 10..300_000 and is_integer(timeout) and timeout in 10..300_000 and
        (Keyword.has_key?(opts, :poll) or
           (match?({module, _} when is_atom(module), source) and is_function(router, 1)))

    %{
      "gmail_notifications" => %{
        run: fn _ -> run(poll, wake, interval) end,
        timeout_ms: timeout,
        queue: :notification
      }
    }
  end

  defp run(poll, wake, interval) do
    case poll.() do
      {:ok, %{recorded: recorded, failed: failed}}
      when is_integer(recorded) and recorded >= 0 and is_integer(failed) and failed >= 0 ->
        if recorded > 0, do: safe_wake(wake)
        if failed > 0, do: retry(interval), else: {:next, nil, interval}

      _ ->
        retry(interval)
    end
  rescue
    _ -> retry(interval)
  catch
    _, _ -> retry(interval)
  end

  defp retry(interval),
    do: {:retry, min(interval * Integer.pow(2, min(Jobs.failure_count() + 1, 8)), 300_000)}

  defp safe_wake(callback) do
    callback.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
