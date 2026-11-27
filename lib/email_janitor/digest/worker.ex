defmodule EmailJanitor.Digest.Worker do
  @moduledoc """
  Durable per-inbox Oban digest cadence. Discovery enumerates trusted connected
  inboxes; callbacks and scope remain runtime-only. Snapshot/outbox ledgers remain
  authoritative across retries. The optional facade supports explicit run_once.
  """
  use GenServer
  alias EmailJanitor.{Digest, Jobs}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def run(pid), do: GenServer.call(pid, :run, :infinity)
  @impl true
  def init(opts), do: {:ok, opts}
  @impl true
  def handle_call(:run, _from, opts), do: {:reply, run_once(opts), opts}

  def tasks(opts) do
    jobs = Keyword.fetch!(opts, :jobs)

    %{
      "digest_discovery" => %{
        run: fn _ -> discover(jobs, opts) end,
        timeout_ms: 30_000,
        queue: :discovery
      },
      "digest" => %{
        run: fn key -> deliver_key(key, opts) end,
        timeout_ms: 300_000,
        queue: :digest,
        seed?: false
      }
    }
  end

  defp discover(jobs, opts) do
    with {:ok, inboxes} <- trusted_inboxes(opts),
         keys = Enum.map(inboxes, &inbox_key/1),
         :ok <- Jobs.reconcile_keys(jobs, "digest", keys),
         true <- Enum.all?(keys, &match?({:ok, _}, Jobs.enqueue(jobs, "digest", &1))) do
      {:next, nil, 60_000}
    else
      _ -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp deliver_key(key, opts) do
    with {:ok, inboxes} <- trusted_inboxes(opts) do
      case Enum.filter(inboxes, &(inbox_key(&1) == key)) do
        [] ->
          :done

        [{scope, id}] ->
          case run_inbox(scope, id, opts) do
            result when result in [:idle, :sent, :deferred] -> {:next, key, 60_000}
            _ -> :failed
          end

        _ ->
          :failed
      end
    else
      _ -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp trusted_inboxes(opts) do
    case Keyword.fetch!(opts, :inboxes).() do
      inboxes when is_list(inboxes) and length(inboxes) <= 10_000 ->
        if Enum.all?(inboxes, fn
             {%EmailJanitor.Store.Scope{}, id} -> is_binary(id) and byte_size(id) in 1..256
             _ -> false
           end),
           do: {:ok, Enum.uniq(inboxes)},
           else: {:error, :digest_worker_unavailable}

      _ ->
        {:error, :digest_worker_unavailable}
    end
  end

  defp inbox_key({scope, id}),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({scope.repo, scope.prefix, id}))
      |> Base.encode16(case: :lower)

  def run_once(opts) do
    inboxes = Keyword.fetch!(opts, :inboxes).()
    results = Enum.map(inboxes, fn {scope, inbox_id} -> run_inbox(scope, inbox_id, opts) end)
    {:ok, Enum.frequencies(results)}
  rescue
    _ -> {:error, :digest_worker_unavailable}
  catch
    _, _ -> {:error, :digest_worker_unavailable}
  end

  defp run_inbox(scope, inbox_id, opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    claim =
      Keyword.get(opts, :claim_extras, fn _, _, _, _, _ ->
        {:error, :hypothetical_policy_required}
      end)

    claim = fn inbox, digest, cutoff, ids -> claim.(scope, inbox, digest, cutoff, ids) end

    with {:ok, _} <- Digest.tick(scope, inbox_id, clock.(), claim) do
      case Digest.pending(scope, inbox_id) do
        nil ->
          :idle

        snapshot ->
          authorize = Keyword.fetch!(opts, :authorize)
          footer = Keyword.get(opts, :footer, fn _, _ -> "" end).(scope, inbox_id)

          case Digest.deliver(
                 scope,
                 snapshot.id,
                 Keyword.fetch!(opts, :mail),
                 fn inbox -> authorize.(scope, inbox) end,
                 clock: clock,
                 footer: footer
               ) do
            :ok -> :sent
            {:error, :mail_admission_rejected} -> :deferred
            _ -> :failed
          end
      end
    else
      _ -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end
end
