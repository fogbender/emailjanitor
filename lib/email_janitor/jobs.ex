defmodule EmailJanitor.Jobs do
  @moduledoc """
  Oban-backed background cadence. Only opaque task keys and continuation markers
  enter PostgreSQL; callbacks and provider configuration stay in the host runtime.
  Gmail/SES effect ledgers remain authoritative when a job is retried or rescued.
  """
  use Supervisor
  import Ecto.Query
  alias EmailJanitor.Jobs.Worker

  @active ~w(available scheduled executing retryable)
  @failure_key {__MODULE__, :failures}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    tasks = Keyword.fetch!(opts, :tasks)
    true = valid_tasks?(tasks)

    oban =
      [
        repo: Keyword.fetch!(opts, :repo),
        prefix: Keyword.fetch!(opts, :prefix),
        name: name,
        queues: [mail: 4],
        notifier: Oban.Notifiers.PG,
        lifeline: [rescue_after: {25, :minutes}],
        pruner: [max_age: {1, :day}],
        log: false
      ]
      |> Keyword.merge(Keyword.get(opts, :oban, []))
      |> Keyword.put(:name, name)
      |> Keyword.put(:repo, Keyword.fetch!(opts, :repo))
      |> Keyword.put(:prefix, Keyword.fetch!(opts, :prefix))
      |> Keyword.put(:log, false)

    children = [
      %{id: :definitions, start: {Agent, :start_link, [fn -> tasks end, [name: registry(name)]]}},
      {Oban, oban}
    ]

    children =
      if Keyword.get(opts, :seed, true) do
        children ++
          [%{id: :seed, start: {__MODULE__, :seed_start, [name, tasks]}, restart: :transient}]
      else
        children
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def seed_start(name, tasks) do
    for {task, definition} <- tasks, Map.get(definition, :seed?, true) do
      {:ok, _} = enqueue(name, task)
    end

    recover_wakes(name, Map.keys(tasks))
    :ignore
  end

  defp recover_wakes(name, tasks) do
    conf = Oban.config(name)

    args =
      conf.repo.all(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(Worker) and
              j.args["task"] in ^tasks and j.args["wake"] == true and j.state in ^@active,
          select: j.args
        ),
        prefix: conf.prefix,
        log: false
      )

    for arg <- args, valid_args?(arg) do
      :ok = wake(name, arg["task"], arg["key"], repair?: arg["repair"])
    end

    :ok
  end

  def enqueue(name, task, metadata \\ nil, opts \\ []) do
    key = Keyword.get(opts, :key, metadata || task)

    with true <- valid_marker?(metadata) and valid_key?(key),
         {:ok, definition} <- definition(name, task) do
      args = %{
        "task" => task,
        "key" => key,
        "metadata" => metadata,
        "failures" => 0,
        "wake" => false,
        "repair" => false
      }

      changeset =
        Worker.new(args,
          queue: Map.get(definition, :queue, :mail),
          unique: [
            period: :infinity,
            fields: [:worker, :args],
            keys: [:task, :key],
            states: ~w(available scheduled executing retryable)a
          ]
        )

      Oban.insert(name, changeset)
    else
      _ -> {:error, :invalid_job}
    end
  rescue
    _ -> {:error, :job_unavailable}
  catch
    _, _ -> {:error, :job_unavailable}
  end

  @doc "Wake healthy work; only an authenticated host repair may bypass failure backoff."
  def wake(name, task, key, opts \\ []) do
    repair? = Keyword.get(opts, :repair?, false) == true

    with true <- valid_key?(key), {:ok, _} <- definition(name, task) do
      locked(name, task, key, fn job ->
        failures = Map.get(job.args, "failures", 0)

        if repair? or failures == 0 do
          args = job.args |> Map.put("wake", true) |> Map.put("repair", repair?)
          {:ok, _} = Oban.update_job(name, job, %{args: args})
          if job.state != "executing", do: Oban.retry_job(name, job)
        end

        :ok
      end)
    else
      _ -> {:error, :invalid_job}
    end
  rescue
    _ -> {:error, :job_unavailable}
  catch
    _, _ -> {:error, :job_unavailable}
  end

  def cancel(name, task, key) do
    conf = Oban.config(name)

    ids =
      conf.repo.all(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(Worker) and
              j.args["task"] == ^task and j.args["key"] == ^key and j.state in ^@active,
          select: j.id
        ),
        prefix: conf.prefix,
        log: false
      )

    Enum.each(ids, &Oban.cancel_job(name, &1))
    :ok
  end

  def reconcile_keys(name, task, keys) do
    conf = Oban.config(name)

    ids =
      conf.repo.all(
        from(j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(Worker) and
              j.args["task"] == ^task and j.args["key"] not in ^keys and j.state in ^@active,
          select: j.id
        ),
        prefix: conf.prefix,
        log: false
      )

    Enum.each(ids, &Oban.cancel_job(name, &1))
    :ok
  end

  @doc "Failure count of this task's previous durable attempts, available inside its callback."
  def failure_count, do: Process.get(@failure_key, 0)

  @doc false
  def attach_telemetry do
    case :telemetry.attach(
           {__MODULE__, :pending_wake},
           [:oban, :job, :stop],
           &__MODULE__.after_ack/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # Oban emits :stop after persisting its acknowledgement. A wake arriving after
  # our checkpoint but before that acknowledgement must not inherit the old delay.
  @doc false
  def after_ack(
        _,
        _,
        %{state: :snoozed, job: %Oban.Job{conf: conf, worker: worker, args: args}},
        _
      )
      when worker == "EmailJanitor.Jobs.Worker" do
    if Registry.lookup(EmailJanitor.JobRegistry, conf.name) != [] and valid_args?(args) do
      locked(conf.name, args["task"], args["key"], fn current ->
        if current.args["wake"] and
             (current.args["repair"] or current.args["failures"] == 0) do
          Oban.retry_job(conf.name, current)
        end

        :ok
      end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def after_ack(_, _, _, _), do: :ok

  @doc false
  def execute(%Oban.Job{conf: conf, args: args} = job) do
    with true <- valid_args?(args), {:ok, definition} <- definition(conf.name, args["task"]) do
      result =
        EmailJanitor.Owner.background(
          fn ->
            Process.put(@failure_key, args["failures"])
            definition.run.(args["metadata"])
          end,
          definition.timeout_ms
        )

      checkpoint(conf.name, job, result, definition)
    else
      _ -> {:cancel, :invalid_job}
    end
  rescue
    _ -> {:snooze, 60}
  catch
    _, _ -> {:snooze, 60}
  end

  defp checkpoint(name, job, result, definition) do
    conf = Oban.config(name)

    case conf.repo.transaction(
           fn ->
             current =
               conf.repo.one!(from(j in Oban.Job, where: j.id == ^job.id, lock: "FOR UPDATE"),
                 prefix: conf.prefix,
                 log: false
               )

             case next(result, current.args) do
               :done ->
                 :ok

               {metadata, delay, failed?} ->
                 # This trusted host callback is DB-only. The job-row lock also
                 # serializes it with deletion's metadata purge.
                 metadata = guarded_metadata(conf.repo, definition, metadata)
                 repair? = current.args["repair"] == true
                 wake? = current.args["wake"] == true and (not failed? or repair?)

                 failures =
                   if failed? and not repair?, do: min(current.args["failures"] + 1, 32), else: 0

                 args = %{
                   current.args
                   | "metadata" => metadata,
                     "failures" => failures,
                     "wake" => false,
                     "repair" => false
                 }

                 {:ok, _} = Oban.update_job(name, current, %{args: args})
                 # Oban owns scheduling, retries after process death, and queue concurrency.
                 {:snooze, if(wake?, do: 0, else: div(delay + 999, 1_000))}
             end
           end,
           log: false
         ) do
      {:ok, result} -> result
      _ -> {:snooze, 60}
    end
  end

  defp guarded_metadata(repo, definition, metadata) do
    guard = Map.get(definition, :metadata_guard, fn marker -> {:ok, marker} end)

    case guard.(metadata) do
      {:ok, marker} ->
        if valid_marker?(marker), do: marker, else: repo.rollback(:invalid_job_metadata)

      _ ->
        repo.rollback(:invalid_job_metadata)
    end
  end

  defp next(:done, _), do: :done

  defp next({:next, marker, delay}, args) when is_integer(delay) and delay in 0..86_400_000 do
    if valid_marker?(marker), do: {marker, delay, false}, else: {args["metadata"], 60_000, true}
  end

  defp next({:retry, delay}, args) when is_integer(delay) and delay in 0..86_400_000,
    do: {args["metadata"], delay, true}

  defp next(_, args), do: {args["metadata"], 60_000, true}

  defp locked(name, task, key, fun) do
    conf = Oban.config(name)

    conf.repo.transaction(
      fn ->
        query =
          from(j in Oban.Job,
            where:
              j.worker == ^Oban.Worker.to_string(Worker) and
                j.args["task"] == ^task and j.args["key"] == ^key and j.state in ^@active,
            lock: "FOR UPDATE"
          )

        case conf.repo.one(query, prefix: conf.prefix, log: false) do
          nil -> {:error, :not_found}
          job -> fun.(job)
        end
      end,
      log: false
    )
    |> case do
      {:ok, result} -> result
      _ -> {:error, :job_unavailable}
    end
  end

  defp definition(name, task) do
    Agent.get(registry(name), &Map.fetch(&1, task))
  end

  defp registry(name), do: {:via, Registry, {EmailJanitor.JobRegistry, name}}
  defp valid_marker?(nil), do: true
  defp valid_marker?(value), do: valid_key?(value)
  defp valid_key?(value), do: is_binary(value) and byte_size(value) in 1..1024

  defp valid_args?(
         %{
           "task" => task,
           "key" => key,
           "metadata" => marker,
           "failures" => failures,
           "wake" => wake,
           "repair" => repair
         } = args
       ),
       do:
         map_size(args) == 6 and valid_key?(task) and valid_key?(key) and valid_marker?(marker) and
           is_integer(failures) and failures in 0..32 and is_boolean(wake) and is_boolean(repair)

  defp valid_args?(_), do: false

  defp valid_tasks?(tasks) when is_map(tasks) do
    Enum.all?(tasks, fn {name, definition} ->
      valid_key?(name) and is_function(definition[:run], 1) and
        is_integer(definition[:timeout_ms]) and definition.timeout_ms in 1..1_200_000 and
        is_atom(Map.get(definition, :queue, :mail)) and
        (not Map.has_key?(definition, :metadata_guard) or
           is_function(definition.metadata_guard, 1))
    end)
  end

  defp valid_tasks?(_), do: false
end
