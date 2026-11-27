defmodule EmailJanitor.JobsGuardTestRepo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.JobsMetadataGuardTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.JobsGuardTestRepo, as: Repo
  alias EmailJanitor.Jobs
  @name EmailJanitor.JobsMetadataGuardTest.Oban
  @prefix "ej_jobs_guard"

  setup do
    start_supervised!(
      {Repo,
       socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
       database: "emailjanitor_test",
       username: System.fetch_env!("USER"),
       port: 5432,
       pool_size: 5,
       log: false}
    )

    Repo.query!("DROP SCHEMA IF EXISTS ej_jobs_guard CASCADE", [], log: false)
    Repo.query!("CREATE SCHEMA ej_jobs_guard", [], log: false)
    Ecto.Migrator.up(Repo, 1, EmailJanitor.Jobs.Migration, prefix: @prefix, log: false)
    Repo.query!("CREATE TABLE ej_jobs_guard.inboxes (id text PRIMARY KEY)", [], log: false)
    Repo.query!("INSERT INTO ej_jobs_guard.inboxes VALUES ('deleted-inbox')", [], log: false)
    :ok
  end

  for order <- [:deletion_first, :checkpoint_first] do
    test "a deleted-account cursor cannot survive #{order} ordering" do
      assert_guard_order(unquote(order))
    end
  end

  defp assert_guard_order(order) do
    observer = self()

    guard = fn marker ->
      if order == :checkpoint_first do
        send(observer, {:guard_locked, self()})

        receive do
          :continue -> :ok
        end
      end

      %{rows: [[exists]]} =
        Repo.query!("SELECT EXISTS(SELECT 1 FROM ej_jobs_guard.inboxes WHERE id=$1)", [marker],
          log: false
        )

      {:ok, if(exists, do: marker, else: nil)}
    end

    task = %{
      run: fn _ ->
        send(observer, {:running, self()})

        receive do
          :continue -> {:next, "deleted-inbox", 60_000}
        end
      end,
      timeout_ms: 10_000,
      metadata_guard: guard
    }

    start_supervised!(
      {Jobs,
       name: @name,
       repo: Repo,
       prefix: @prefix,
       tasks: %{"digest" => task},
       oban: [testing: :manual]}
    )

    [job] = Repo.all(Oban.Job, prefix: @prefix, log: false)
    job = %{job | conf: Oban.config(@name)}
    executor = Task.async(fn -> EmailJanitor.Jobs.Worker.perform(job) end)
    assert_receive {:running, owner}, 3_000

    delete = fn ->
      Repo.transaction(
        fn ->
          Repo.query!("SELECT id FROM ej_jobs_guard.oban_jobs WHERE id=$1 FOR UPDATE", [job.id],
            log: false
          )

          send(observer, {:delete_locked, self()})

          receive do
            :continue -> :ok
          end

          Repo.query!(
            "UPDATE ej_jobs_guard.oban_jobs SET args=jsonb_set(args, '{metadata}', 'null') WHERE id=$1",
            [job.id],
            log: false
          )

          Repo.query!("DELETE FROM ej_jobs_guard.inboxes WHERE id='deleted-inbox'", [],
            log: false
          )
        end,
        log: false
      )
    end

    deleter =
      if order == :deletion_first do
        task = Task.async(delete)
        assert_receive {:delete_locked, deleting}, 3_000
        send(owner, :continue)
        await_lock()
        send(deleting, :continue)
        task
      else
        send(owner, :continue)
        assert_receive {:guard_locked, guarding}, 3_000
        task = Task.async(delete)
        await_lock()
        send(guarding, :continue)
        assert_receive {:delete_locked, deleting}, 3_000
        send(deleting, :continue)
        task
      end

    assert {:ok, _} = Task.await(deleter)
    assert {:snooze, 60} = Task.await(executor)
    assert Repo.get!(Oban.Job, job.id, prefix: @prefix, log: false).args["metadata"] == nil
    assert :ok = stop_supervised({Jobs, @name})
    Repo.query!("DROP SCHEMA ej_jobs_guard CASCADE", [], log: false)
  end

  defp await_lock(attempts \\ 100)
  defp await_lock(0), do: flunk("expected an actual PostgreSQL row-lock waiter")

  defp await_lock(attempts) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%ej_jobs_guard%oban_jobs%'",
        [],
        log: false
      )

    if count > 0,
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_lock(attempts - 1)
        )
  end
end
