defmodule EmailJanitor.WorkerTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, Fixtures, Worker, Policy, Store}
  alias EmailJanitor.Gmail.Ingestion
  alias EmailJanitor.Worker.{Config, Receipt, Deferral, Candidate}
  alias EmailJanitor.Store.{Action, Scope}
  alias __MODULE__.{Repo, Gmail, Classifier}

  setup_all do
    start_supervised!(
      {Repo,
       [
         socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
         database: "emailjanitor_test",
         username: System.fetch_env!("USER"),
         port: 5432,
         pool_size: 10,
         log: false
       ]}
    )

    :ok
  end

  setup do
    prefix = "ej_worker_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, scope} = Scope.new(Repo, prefix)
    :ok = Worker.install(scope)
    box = Fixtures.inbox()
    {:ok, _} = Store.add_inbox(scope, box)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             watch_id: "100",
             revision: "revision-1",
             arrivals: %{"100" => %{through: "101", ids: ["message-1"]}},
             messages: [Fixtures.message(body: "PRIVATE_BODY_SENTINEL")],
             calls: [],
             mutations: [],
             model: :done,
             model_inputs: [],
             mutation: :ok,
             evidence: []
           }
         end}
      )

    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end}, id: :clock)

    quota =
      start_supervised!({Agent, fn -> %{block: nil, failures: 0, calls: []} end}, id: :quota)

    {:ok, config} =
      Config.new(scope, box,
        gmail: {Gmail, [state: state]},
        classifier: {Classifier, [state: state]},
        preferences: fn ->
          {:ok, Content.new("Synthetic instructions"),
           Store.instruction_version(scope, box.id) |> elem(1)}
        end,
        authorize: fn -> :ok end,
        topic: "projects/emailjanitor-test/topics/mailbox",
        clock: fn -> Agent.get(clock, & &1) end,
        policy: %Policy{adapter: __MODULE__.Policy, context: quota}
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, ~s|DROP SCHEMA "#{prefix}" CASCADE|, [], log: false)
    end)

    %{scope: scope, box: box, state: state, clock: clock, quota: quota, config: config}
  end

  defp advance(clock, seconds), do: Agent.update(clock, &DateTime.add(&1, seconds))
  defp read(state), do: Agent.get(state, & &1)
  defp pending(ctx), do: Ingestion.pending(ctx.scope, ctx.box)

  test "install is idempotent and the first watch seeds no old-inbox cleanup", ctx do
    assert :ok = Worker.install(ctx.scope)

    Agent.update(
      ctx.state,
      &%{&1 | arrivals: %{}, messages: [Fixtures.message(id: "old-message")]}
    )

    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == [] and read(ctx.state).model_inputs == []
    assert {:ok, checkpoint} = Ingestion.checkpoint(ctx.scope, ctx.box.id)
    assert checkpoint.baseline_id == "100" and checkpoint.cursor == "100"
  end

  test "new arrivals are classified and exact INBOX-only mutations complete once", ctx do
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == [["message-1"]]
    assert [%{labels: ["UNREAD", "IMPORTANT"]}] = read(ctx.state).messages
    assert {:ok, []} = pending(ctx)
    assert {:ok, %{status: :idle, recovery: :settled}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == [["message-1"]]
    assert [%Receipt{status: :settled}] = Repo.all(Receipt, prefix: ctx.scope.prefix)
  end

  test "worker objects redact prompts, credentials and callbacks", ctx do
    output = inspect(ctx.config)
    refute output =~ "Synthetic instructions"
    refute output =~ "PRIVATE_BODY_SENTINEL"
    refute output =~ "state:"
  end

  test "unreadable content remains pending and same revision is only metadata-probed", ctx do
    Agent.update(ctx.state, &%{&1 | model: :unreadable})
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
    before = read(ctx.state)
    assert length(before.model_inputs) == 1
    assert {:ok, [_]} = pending(ctx)

    assert [%Deferral{status: :unreadable, fingerprint: "revision-1", instruction_version: 1}] =
             Repo.all(Deferral, prefix: ctx.scope.prefix)

    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    advance(ctx.clock, 901)
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
    assert read(ctx.state).model_inputs == before.model_inputs

    assert Enum.count(read(ctx.state).calls, &(&1 == :full_thread)) ==
             Enum.count(before.calls, &(&1 == :full_thread))

    Agent.update(ctx.state, &%{&1 | revision: "revision-2", model: :done})
    advance(ctx.clock, 901)
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == 2
  end

  test "instruction changes release stable deferred work and transient model failures retry",
       ctx do
    Agent.update(ctx.state, &%{&1 | model: :unreadable})
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

    Repo.update_all(EmailJanitor.Store.Mailbox, [set: [instruction_version: 2]],
      prefix: ctx.scope.prefix,
      log: false
    )

    Agent.update(ctx.state, &%{&1 | model: :error})
    assert {:ok, %{status: :model_unavailable}} = Worker.step(ctx.config)
    assert {:ok, [_]} = pending(ctx)

    assert [%Deferral{status: :transient, instruction_version: 2}] =
             Repo.all(Deferral, prefix: ctx.scope.prefix)

    Agent.update(ctx.state, &%{&1 | model: :done})
    advance(ctx.clock, 901)
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
  end

  test "a transient blocked reservation preserves arrival provenance", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :already_reserved})
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
    assert {:ok, [_]} = pending(ctx)
    assert read(ctx.state).mutations == []
    Agent.update(ctx.quota, &%{&1 | block: nil})
    advance(ctx.clock, 901)
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
  end

  test "terminal settlement errors survive a new worker step without another mutation", ctx do
    Agent.update(ctx.quota, &%{&1 | failures: 1})
    assert {:ok, %{status: :settlement_pending}} = Worker.step(ctx.config)
    assert [%Action{state: :done}] = Repo.all(Action, prefix: ctx.scope.prefix)
    assert {:ok, %{recovery: :settled}} = Worker.step(ctx.config)
    assert [%Receipt{status: :settled}] = Repo.all(Receipt, prefix: ctx.scope.prefix)
    assert read(ctx.state).mutations == [["message-1"]]
  end

  test "ambiguous dispatch is reconciled with fresh complete history, never resent", ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | mutation: :timeout_after_apply,
          evidence: [%{history_id: "201", message_id: "message-1", event: :inbox_removed}]
      }
    )

    assert {:ok, %{status: :unresolved}} = Worker.step(ctx.config)
    assert [%Action{state: :unresolved}] = Repo.all(Action, prefix: ctx.scope.prefix)
    assert {:ok, %{recovery: :settled}} = Worker.step(ctx.config)
    assert [%Action{state: :done}] = Repo.all(Action, prefix: ctx.scope.prefix)
    assert read(ctx.state).mutations == [["message-1"]]
  end

  test "old context remains in inbox while only a known new target is cleaned", ctx do
    Agent.update(
      ctx.state,
      &%{&1 | messages: [Fixtures.message(id: "old-message"), Fixtures.message()]}
    )

    assert {:ok, %{status: :done}} = Worker.step(ctx.config)

    assert [%{id: "old-message", labels: old_labels}, %{id: "message-1", labels: new_labels}] =
             read(ctx.state).messages

    assert "INBOX" in old_labels
    refute "INBOX" in new_labels
    assert read(ctx.state).model_inputs == [["old-message", "message-1"]]
  end

  test "quota-blocked candidates recheck across explicit reconnect using known provenance", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    assert {:ok, []} = pending(ctx)

    assert [%Candidate{status: :pending, candidate_id: id}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert {:ok, old} = Ingestion.checkpoint(ctx.scope, ctx.box.id)

    assert {:ok, _} =
             Ingestion.reconnect(ctx.scope, ctx.box, old.generation, %{
               history_id: "500",
               expires_at: DateTime.add(DateTime.utc_now(), 604_800)
             })

    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, id)
    Agent.update(ctx.quota, &%{&1 | block: nil})
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == [["message-1"]]
  end

  test "host authorization failure performs no watch, classifier or mutation", ctx do
    config = %{ctx.config | authorize: fn -> {:error, :disconnected} end}
    assert {:ok, %{status: :connection_changed}} = Worker.step(config)

    assert read(ctx.state).calls == [] and read(ctx.state).model_inputs == [] and
             read(ctx.state).mutations == []
  end

  test "verified self mail is excluded from targets and all model context", ctx do
    digest =
      Fixtures.message(
        id: "janitor-digest",
        from: "janitor@emailjanitor.net",
        headers: [{"From", "janitor@emailjanitor.net"}, {"Message-ID", "<recorded@ses.example>"}],
        body: "UPGRADE_DIGEST_MUST_NOT_REACH_MODEL"
      )

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [digest, Fixtures.message()],
          arrivals: %{"100" => %{through: "101", ids: ["janitor-digest", "message-1"]}}
      }
    )

    self_mail = fn headers -> {:ok, {"Message-ID", "<recorded@ses.example>"} in headers} end
    config = %{ctx.config | self_mail: self_mail}
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).model_inputs == [["message-1"]]
    assert read(ctx.state).mutations == [["message-1"]]
    assert {:reserve, ["janitor-digest", "message-1"]} in read(ctx.quota).calls
    assert "INBOX" in hd(read(ctx.state).messages).labels
  end

  test "same-sender mail without scoped delivery evidence still reaches classifier", ctx do
    Agent.update(
      ctx.state,
      &%{&1 | messages: [Fixtures.message(from: "janitor@emailjanitor.net")]}
    )

    config = %{ctx.config | self_mail: fn _ -> {:ok, false} end}
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).model_inputs == [["message-1"]]
  end

  test "unavailable self-mail evidence fails closed without retiring or changing mail", ctx do
    import ExUnit.CaptureLog
    config = %{ctx.config | self_mail: fn _ -> raise "PRIVATE_RECEIPT_FAILURE" end}

    logs =
      capture_log(fn ->
        assert {:ok, %{status: :self_mail_unavailable}} = Worker.step(config)
      end)

    refute logs =~ "PRIVATE_RECEIPT_FAILURE"
    assert read(ctx.state).model_inputs == [] and read(ctx.state).mutations == []
    assert {:ok, [_]} = pending(ctx)
    assert Repo.all(Candidate, prefix: ctx.scope.prefix) == []
  end

  test "unpaid recheck keeps provenance without retrying until upgrade requeues it", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    assert {:ok, 1} = Worker.queue_backlog(ctx.scope, ctx.box)
    config = %{ctx.config | allow_recheck: fn _ -> {:blocked, :upgrade_required} end}
    assert {:ok, %{status: :blocked}} = Worker.step(config)

    assert [%Candidate{status: :pending, requested: false}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    count = length(read(ctx.state).model_inputs)
    advance(ctx.clock, 901)
    assert {:ok, %{status: :idle}} = Worker.step(config)
    assert length(read(ctx.state).model_inputs) == count
    Agent.update(ctx.quota, &%{&1 | block: nil})
    assert {:ok, 1} = Worker.queue_backlog(ctx.scope, ctx.box)
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
  end

  test "history expiry pauses without resetting the baseline or cleaning backlog", ctx do
    Agent.update(ctx.state, &%{&1 | arrivals: %{}})
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert {:ok, original} = Ingestion.checkpoint(ctx.scope, ctx.box.id)
    config = %{ctx.config | gmail: {Gmail, [state: ctx.state, history_expired: true]}}
    assert {:ok, %{status: :history_gap}} = Worker.step(config)
    assert {:ok, paused} = Ingestion.checkpoint(ctx.scope, ctx.box.id)
    assert paused.status == :gap
    assert paused.generation == original.generation and paused.baseline_id == original.baseline_id
    assert {:ok, %{status: :history_gap}} = Worker.step(ctx.config)
    assert Enum.count(read(ctx.state).calls, &(&1 == :watch)) == 1
    assert read(ctx.state).mutations == []
  end

  test "watch renewal preserves durable cursor and never becomes a new baseline", ctx do
    Agent.update(ctx.state, &%{&1 | arrivals: %{}})
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert {:ok, original} = Ingestion.checkpoint(ctx.scope, ctx.box.id)
    advance(ctx.clock, 43_201)
    Agent.update(ctx.state, &%{&1 | watch_id: "999"})
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert {:ok, current} = Ingestion.checkpoint(ctx.scope, ctx.box.id)
    assert current.cursor == "100" and current.baseline_id == "100"
    assert current.generation == original.generation
    assert :renew in read(ctx.state).calls
  end

  test "at most five targets are admitted per step and remaining arrivals continue", ctx do
    messages = Enum.map(1..7, &Fixtures.message(id: "arrival-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert [ids] = read(ctx.state).mutations
    assert length(ids) == 5
    assert {:ok, remaining} = pending(ctx)
    assert length(remaining) == 2
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert [first, second] = read(ctx.state).mutations
    assert length(second) == 2 and MapSet.disjoint?(MapSet.new(first), MapSet.new(second))
    assert {:ok, []} = pending(ctx)
  end

  test "a disconnect queued during admission invalidates the prepared mutation at final fence",
       ctx do
    owner = self()

    hook = fn ->
      executor = self()

      {:ok, _} =
        Task.start(fn ->
          {:ok, :ok} =
            Repo.transaction(fn ->
              %{rows: [[backend]]} =
                Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [], log: false)

              send(executor, {:disconnect_backend, backend})

              Ecto.Adapters.SQL.query!(
                Repo,
                ~s|SELECT id FROM "#{ctx.scope.prefix}".inboxes WHERE id = $1 FOR UPDATE|,
                [ctx.box.id],
                log: false
              )

              Repo.update_all(EmailJanitor.Store.Mailbox, [inc: [instruction_version: 1]],
                prefix: ctx.scope.prefix,
                log: false
              )

              :ok
            end)

          send(owner, :disconnected)
        end)

      receive do
        {:disconnect_backend, backend} -> await_blocked(backend, 100)
      after
        2_000 -> flunk("disconnect task did not start")
      end
    end

    Agent.update(ctx.quota, &Map.put(&1, :reserve_hook, hook))
    assert {:ok, %{status: status}} = Worker.step(ctx.config)
    assert status == :proposal_changed
    assert_receive :disconnected, 1_000
    assert read(ctx.state).mutations == []

    assert [%Action{state: :cancelled, dispatch_started_at: nil}] =
             Repo.all(Action, prefix: ctx.scope.prefix)

    assert [%Candidate{status: :pending}] = Repo.all(Candidate, prefix: ctx.scope.prefix)

    # A fresh accepted Keep must atomically retire even cancelled-action provenance;
    # later upgrades cannot resurrect that stale high-confidence Done candidate.
    Agent.update(ctx.quota, &Map.delete(&1, :reserve_hook))
    Agent.update(ctx.state, &%{&1 | model: :keep})
    assert {:ok, %{status: :kept, recovery: :settled}} = Worker.step(ctx.config)

    assert [%Candidate{status: :retired, requested: false}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert {:ok, 0} = Worker.queue_backlog(ctx.scope, ctx.box)
  end

  defp await_blocked(_backend, 0),
    do: flunk("disconnect must queue behind the mailbox admission lock")

  defp await_blocked(backend, attempts) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT cardinality(pg_blocking_pids($1))", [backend],
        log: false
      )

    if count > 0 do
      :ok
    else
      Process.sleep(5)
      await_blocked(backend, attempts - 1)
    end
  end
end
