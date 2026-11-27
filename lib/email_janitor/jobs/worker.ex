defmodule EmailJanitor.Jobs.Worker do
  @moduledoc false
  use Oban.Worker, queue: :mail, max_attempts: 1_000_000_000

  @impl true
  def perform(job), do: EmailJanitor.Jobs.execute(job)

  # Runtime failures are caught before Oban can persist exception/model text.
  # The independent Owner watchdog bounds execution and follows caller death.
  @impl true
  def timeout(_), do: :infinity

  @impl true
  def backoff(_), do: 60
end
