defmodule EmailJanitor.Digest.Worker do
  @moduledoc """
  Supervised minute scheduler. Host callbacks enumerate trusted connected inboxes
  and route Scope/authorization/policy; no tenant or billing logic lives here.
  Database schedules/outbox fences survive restarts; no body enters worker state.
  """
  use GenServer
  alias EmailJanitor.Digest

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def run(pid), do: GenServer.call(pid, :run, :infinity)

  @impl true
  def init(opts) do
    send(self(), :tick)
    {:ok, opts}
  end

  @impl true
  def handle_info(:tick, opts) do
    run_once(opts)
    Process.send_after(self(), :tick, 60_000)
    {:noreply, opts}
  end

  @impl true
  def handle_call(:run, _from, opts), do: {:reply, run_once(opts), opts}

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
