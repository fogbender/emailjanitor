defmodule EmailJanitor.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    EmailJanitor.Jobs.attach_telemetry()

    children = [
      {Registry, keys: :unique, name: EmailJanitor.JobRegistry},
      {Task.Supervisor, name: EmailJanitor.ExecutorSupervisor}
    ]

    if EmailJanitor.SelfHost.Config.enabled?() do
      case EmailJanitor.SelfHost.Config.load() do
        {:ok, config} ->
          Supervisor.start_link(children ++ [{EmailJanitor.SelfHost.Supervisor, config}],
            strategy: :one_for_one,
            name: EmailJanitor.Supervisor
          )

        _ ->
          {:error, :invalid_self_host_config}
      end
    else
      Supervisor.start_link(children, strategy: :one_for_one, name: EmailJanitor.Supervisor)
    end
  end
end
