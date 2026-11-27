defmodule EmailJanitor.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    Supervisor.start_link([{Task.Supervisor, name: EmailJanitor.ExecutorSupervisor}],
      strategy: :one_for_one,
      name: EmailJanitor.Supervisor
    )
  end
end
