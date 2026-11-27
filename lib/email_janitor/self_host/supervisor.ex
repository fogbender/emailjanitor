defmodule EmailJanitor.SelfHost.Supervisor do
  @moduledoc "Opt-in host supervision, isolated from shared-library/SaaS application startup."
  use Supervisor
  alias EmailJanitor.SelfHost
  alias EmailJanitor.SelfHost.{Config, Repo, Runtime}

  def start_link(%Config{} = config) do
    if Runtime.ready?(config) and
         (not config.enable_web or Code.ensure_loaded?(EmailJanitor.SelfHost.Web)),
       do: Supervisor.start_link(__MODULE__, config, name: __MODULE__),
       else: {:error, :incomplete_self_host_release}
  end

  @impl true
  def init(config) do
    web = EmailJanitor.SelfHost.Web

    Application.put_env(:email_janitor, :self_host_config, config)
    children = [{Repo, config.database}, {SelfHost.Services, config}]
    children = if config.enable_web, do: children ++ [{web, config}], else: children
    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule EmailJanitor.SelfHost.Services do
  @moduledoc false
  use Supervisor
  alias EmailJanitor.{Digest, Gmail, SelfHost}
  alias EmailJanitor.SelfHost.{Adapters, Store}

  def start_link(config) do
    case SelfHost.Email.config(config) do
      {:ok, feedback} -> Supervisor.start_link(__MODULE__, {config, feedback}, name: __MODULE__)
      _ -> {:error, :invalid_feedback_runtime}
    end
  end

  @impl true
  def init({config, feedback}) do
    jobs = SelfHost.Oban

    cleanup_opts = [
      jobs: jobs,
      name: SelfHost.CleanupServer,
      list: &Store.worker_refs/0,
      resolve: &SelfHost.Runtime.worker_config/1
    ]

    {tasks, facades} =
      case Adapters.mail(config) do
        {:ok, mail} ->
          digest_opts = [
            jobs: jobs,
            mail: mail,
            inboxes: &active_inboxes/0,
            authorize: &authorize/2
          ]

          tasks = Digest.Worker.tasks(digest_opts)

          if config.google_oauth && is_binary(config.pubsub["JANITOR_GOOGLE_TOPIC"]),
            do:
              {Map.merge(tasks, EmailJanitor.Worker.Server.tasks(cleanup_opts)),
               [{EmailJanitor.Worker.Server, cleanup_opts}]},
            else: {tasks, []}

        _ ->
          {%{}, []}
      end

    tasks =
      case Adapters.pubsub(config) do
        {:ok, source} ->
          Map.merge(
            tasks,
            Gmail.NotificationWorker.Server.tasks(
              source: source,
              router: &Adapters.route/1,
              wake: fn -> wake() end
            )
          )

        _ ->
          tasks
      end

    tasks =
      tasks
      |> Map.merge(SelfHost.Revocations.tasks(config))
      |> Map.merge(SelfHost.Maintenance.tasks())
      |> Map.merge(EmailJanitor.Mail.Receiver.tasks(feedback))

    children =
      [
        {EmailJanitor.Jobs,
         name: jobs,
         repo: SelfHost.Repo,
         prefix: SelfHost.scope().prefix,
         tasks: tasks,
         oban: [
           queues: [
             cleanup: 2,
             discovery: 1,
             notification: 1,
             digest: 1,
             revocations: 1,
             intake: 1,
             process: 1,
             feedback: 1,
             maintenance: 1,
             spool: 1,
             orphan: 1
           ]
         ]}
      ] ++ facades

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp active_inboxes do
    with {:ok, refs} <- Store.refs() do
      Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, inboxes} ->
        case Store.fetch_binding(ref) do
          {:ok, %{state: :active}, inbox} ->
            {:cont, {:ok, [{SelfHost.scope(), inbox.id} | inboxes]}}

          {:ok, _, _} ->
            {:cont, {:ok, inboxes}}

          {:error, :inbox_unavailable} ->
            {:cont, {:ok, inboxes}}

          _ ->
            {:halt, {:error, :digest_worker_unavailable}}
        end
      end)
      |> case do
        {:ok, inboxes} -> inboxes
        error -> error
      end
    else
      _ -> {:error, :digest_worker_unavailable}
    end
  end

  defp authorize(scope, id) do
    with true <- scope == SelfHost.scope(),
         {:ok, refs} <- Store.refs(),
         ref when not is_nil(ref) <- Enum.find(refs, fn {inbox, _} -> inbox == id end),
         {:ok, %{state: :active}, inbox} <- Store.fetch_binding(ref) do
      {:ok, inbox}
    else
      _ -> {:error, :inbox_unavailable}
    end
  end

  defp wake do
    module = EmailJanitor.Worker.Server
    if Process.whereis(SelfHost.CleanupServer), do: module.wake(SelfHost.CleanupServer)
    :ok
  end
end

defmodule EmailJanitor.SelfHost.Maintenance do
  @moduledoc false
  alias EmailJanitor.{Preferences, SelfHost}

  def tasks do
    %{
      "host_maintenance" => %{
        run: fn _ -> maintenance() end,
        timeout_ms: 30_000,
        queue: :maintenance
      }
    }
  end

  defp maintenance do
    with {:ok, :ok} <- Preferences.purge_receipts(SelfHost.scope()) do
      web = EmailJanitor.SelfHost.Web

      result =
        if Code.ensure_loaded?(web) and function_exported?(web, :purge, 0),
          do: web.purge(),
          else: :ok

      if result == :ok, do: {:next, nil, 60_000}, else: :failed
    else
      _ -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end
end
