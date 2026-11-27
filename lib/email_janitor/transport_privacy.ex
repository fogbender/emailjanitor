defmodule EmailJanitor.TransportPrivacy do
  @moduledoc """
  Fail closed when HTTP observers could receive raw provider credentials or bodies.

  Finch telemetry carries requests including headers and bodies. Hosts must keep
  Finch handlers absent and must not change observer configuration while provider
  calls are running. This preflight never detaches or changes host observers.
  """

  def check do
    case :telemetry.list_handlers([:finch]) do
      [] -> :ok
      _ -> {:error, :unsafe_http_observers}
    end
  rescue
    _ -> {:error, :unsafe_http_observers}
  catch
    _, _ -> {:error, :unsafe_http_observers}
  end
end
