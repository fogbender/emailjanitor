defmodule EmailJanitor.SelfHostWeb.Maintenance do
  @moduledoc "Browser metadata expiry, run by the host's durable maintenance task."
  def run do
    EmailJanitor.SelfHostWeb.Auth.purge()
  rescue
    _ -> {:error, :maintenance_unavailable}
  catch
    _, _ -> {:error, :maintenance_unavailable}
  end
end
