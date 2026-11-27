defmodule EmailJanitor.SelfHostWeb.Maintenance do
  @moduledoc "Periodic expiry of browser metadata, independent of future sign-ins."
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, schedule(0)}

  def handle_info(:purge, timer) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    try do
      EmailJanitor.SelfHostWeb.Auth.purge()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    {:noreply, schedule(60_000)}
  end

  defp schedule(delay), do: Process.send_after(self(), :purge, delay)
end
