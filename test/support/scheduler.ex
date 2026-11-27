defmodule EmailJanitor.TestScheduler do
  @moduledoc false
  import Ecto.Query
  require ExUnit.Assertions
  alias EmailJanitor.Jobs
  alias __MODULE__.Repo
  alias EmailJanitor.Worker.Server
  @name EmailJanitor.TestScheduler.Oban

  def start_cleanup(opts) do
    opts = Keyword.put(opts, :jobs, @name)

    start_tasks(Server.tasks(opts),
      queues: [cleanup: Keyword.get(opts, :max_concurrency, 2), discovery: 1]
    )

    ExUnit.Callbacks.start_supervised!({Server, opts})
  end

  def start_tasks(tasks, options \\ []) do
    unless Process.whereis(Repo) do
      ExUnit.Callbacks.start_supervised!(
        {Repo,
         socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
         database: "emailjanitor_test",
         username: System.fetch_env!("USER"),
         port: 5432,
         pool_size: 6,
         log: false}
      )

      prefix = "ej_scheduler_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      Process.put({__MODULE__, :prefix}, prefix)
      Repo.query!(~s(CREATE SCHEMA "#{prefix}"), [], log: false)
      :ok = Ecto.Migrator.up(Repo, 1, Jobs.Migration, prefix: prefix, log: false)
    end

    opts = [
      name: @name,
      repo: Repo,
      prefix: Process.get({__MODULE__, :prefix}),
      tasks: tasks,
      oban:
        Keyword.merge(
          [
            testing: :disabled,
            queues: [notification: 1],
            peer: {Oban.Peers.Isolated, []},
            lifeline: false,
            pruner: false
          ],
          options
        )
    ]

    ExUnit.Callbacks.start_supervised!({Jobs, opts})
    opts
  end

  def jobs, do: @name

  def rows(task) do
    Repo.all(from(j in Oban.Job, where: j.args["task"] == ^task, order_by: j.id),
      prefix: Process.get({__MODULE__, :prefix}),
      log: false
    )
  end

  def row(ref), do: Enum.find(rows("cleanup"), &(&1.args["key"] == ref))

  def await(fun, attempts \\ 150)
  def await(fun, 0), do: ExUnit.Assertions.assert(fun.())

  def await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await(fun, attempts - 1)
        )
  end

  defmodule Repo do
    use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
  end
end
