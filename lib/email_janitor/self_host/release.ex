defmodule EmailJanitor.SelfHost.Release do
  @moduledoc "Ascending migrations for the complete opt-in host; no mail/model call occurs here."
  alias EmailJanitor.SelfHost
  alias EmailJanitor.SelfHost.{Config, Repo}

  @migrations [
    {1, EmailJanitor.Store.Migration},
    {2, EmailJanitor.Store.CandidateMigration},
    {3, EmailJanitor.Preferences.Migration},
    {4, EmailJanitor.Mail.Migration},
    {5, EmailJanitor.Digest.Migration},
    {6, EmailJanitor.Store.TargetMigration},
    {7, EmailJanitor.Restore.Migration},
    {8, EmailJanitor.Conversation.Migration},
    {9, EmailJanitor.Conversation.OwnershipMigration},
    {10, EmailJanitor.Gmail.Ingestion.Migration},
    {11, EmailJanitor.Worker.Migration},
    {12, EmailJanitor.Digest.StagingMigration},
    {13, EmailJanitor.Mail.Feedback.Migration},
    {100, SelfHost.Migration}
  ]

  def migrate do
    with {:ok, config} <- Config.load(),
         true <- Enum.all?(@migrations, fn {_, module} -> Code.ensure_loaded?(module) end),
         true <- not config.enable_web or Code.ensure_loaded?(EmailJanitor.SelfHost.Web),
         {:ok, _} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _} <- Application.ensure_all_started(:postgrex) do
      Application.put_env(:email_janitor, :self_host_config, config)
      {:ok, repo} = Repo.start_link(config.database)

      try do
        scope = SelfHost.scope()
        Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{scope.prefix}"), [], log: false)

        for {version, module} <- @migrations do
          result = Ecto.Migrator.up(Repo, version, module, prefix: scope.prefix, log: false)
          if result not in [:ok, :already_up], do: raise("Email Janitor host migrations failed.")
        end

        web = EmailJanitor.SelfHost.Web

        if Code.ensure_loaded?(web) do
          result = web.install(scope)

          if result not in [:ok, :already_up],
            do: raise("Email Janitor browser migrations failed.")
        end

        result =
          Ecto.Migrator.up(Repo, 102, SelfHost.AuthorityMigration,
            prefix: scope.prefix,
            log: false
          )

        if result not in [:ok, :already_up], do: raise("Email Janitor host migrations failed.")

        if SelfHost.Revocations.install(scope) not in [:ok, :already_up],
          do: raise("Email Janitor revocation migrations failed.")

        if Ecto.Migrator.up(Repo, 104, EmailJanitor.Jobs.Migration,
             prefix: scope.prefix,
             log: false
           ) not in [:ok, :already_up],
           do: raise("Email Janitor background migrations failed.")

        if SelfHost.Transport.install(config) != :ok,
          do: raise("Email Janitor mail transport is not configured.")

        :ok
      after
        Supervisor.stop(repo)
      end
    else
      _ -> raise "Email Janitor host migrations are unavailable or not configured."
    end
  end

  @doc "Local operator entrypoint; loads only configuration and Repo, never web or background jobs."
  def confirm_google_access_removed(inbox_id, request_id, subject, :google_access_removed) do
    with {:ok, config} <- Config.load(),
         {:ok, _} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _} <- Application.ensure_all_started(:postgrex),
         :ok <- Application.put_env(:email_janitor, :self_host_config, config),
         {:ok, repo} <- Repo.start_link(config.database) do
      try do
        SelfHost.Revocations.confirm_manual(inbox_id, request_id, subject, :google_access_removed)
      after
        Supervisor.stop(repo)
      end
    else
      _ -> {:error, :manual_confirmation_unavailable}
    end
  rescue
    _ -> {:error, :manual_confirmation_unavailable}
  end

  def confirm_google_access_removed(_, _, _, _), do: {:error, :invalid_confirmation}
end
