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
    children = [{SelfHost.Maintenance, config}]

    children =
      case Adapters.mail(config) do
        {:ok, mail} ->
          cleanup =
            if config.google_oauth && is_binary(config.pubsub["JANITOR_GOOGLE_TOPIC"]),
              do: [
                {EmailJanitor.Worker.Server,
                 name: SelfHost.CleanupServer,
                 list: &Store.refs/0,
                 resolve: &SelfHost.Runtime.worker_config/1,
                 max_concurrency: 2}
              ],
              else: []

          digest =
            {Digest.Worker,
             name: SelfHost.DigestServer,
             mail: mail,
             inboxes: &active_inboxes/0,
             authorize: &authorize/2}

          children ++ cleanup ++ [digest]

        _ ->
          children
      end

    children =
      case Adapters.pubsub(config) do
        {:ok, source} ->
          children ++
            [
              {Gmail.NotificationWorker.Server,
               name: SelfHost.NotificationServer,
               source: source,
               router: &Adapters.route/1,
               wake: fn -> wake() end}
            ]

        _ ->
          children
      end

    children = children ++ SelfHost.MailJobs.children(feedback)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp active_inboxes do
    with {:ok, refs} <- Store.refs() do
      for ref <- refs,
          {:ok, %{state: :active}, inbox} <- [Store.fetch_binding(ref)],
          do: {SelfHost.scope(), inbox.id}
    else
      _ -> []
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
  use GenServer
  alias EmailJanitor.{Preferences, SelfHost}
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  @impl true
  def init(config) do
    send(self(), :tick)
    {:ok, config}
  end

  @impl true
  def handle_info(:tick, config) do
    maintenance()
    Process.send_after(self(), :tick, 60_000)
    {:noreply, config}
  end

  defp maintenance do
    Preferences.purge_receipts(SelfHost.scope())
    web = EmailJanitor.SelfHost.Web
    if Code.ensure_loaded?(web) and function_exported?(web, :purge, 0), do: web.purge()
    :ok
  rescue
    _ -> :ok
  end
end
