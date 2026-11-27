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

  for scenario <- [:sent, :draft, :own_domain, :contacted] do
    sender = if scenario == :own_domain, do: "janitor@acme.com", else: "janitor@emailjanitor.net"

    labels =
      if scenario in [:sent, :draft],
        do: ["INBOX", String.upcase(Atom.to_string(scenario))],
        else: ["INBOX"]

    contacts = if scenario == :contacted, do: ["emailjanitor.net"], else: []

    test "verified #{scenario} self-mail never shields ordinary siblings, unverified mail retains safeguards",
         ctx do
      sender = unquote(sender)
      labels = unquote(labels)

      delivery =
        Fixtures.message(
          id: "digest",
          from: sender,
          labels: labels,
          headers: [{"From", sender}, {"Message-ID", "<recorded@ses.example>"}]
        )

      Agent.update(ctx.state, fn state ->
        state
        |> Map.put(:messages, [delivery, Fixtures.message()])
        |> Map.put(:arrivals, %{"100" => %{through: "101", ids: ["digest", "message-1"]}})
        |> Map.put(
          :contacts,
          MapSet.new(unquote(contacts))
        )
      end)

      # Sender alone, including a Janitor-looking sender, never grants exemption.
      assert {:ok, %{status: :kept}} = Worker.step(ctx.config)
      assert read(ctx.state).model_inputs == [] and read(ctx.state).mutations == []

      # Newly observed sibling IDs exercise fresh admission, rather than reviving
      # manually/previously processed arrivals after changing proof.
      sibling = Fixtures.message(id: "new-pitch")

      Agent.update(
        ctx.state,
        &%{
          &1
          | messages: [delivery, sibling],
            arrivals: %{"101" => %{through: "102", ids: ["new-pitch"]}}
        }
      )

      config = %{
        ctx.config
        | self_mail: fn headers -> {:ok, {"Message-ID", "<recorded@ses.example>"} in headers} end
      }

      assert {:ok, %{status: :done}} = Worker.step(config)
      assert read(ctx.state).model_inputs == [["new-pitch"]]
      assert read(ctx.state).mutations == [["new-pitch"]]
      assert "INBOX" in hd(read(ctx.state).messages).labels
    end
  end

  test "filtering verified SENT self-mail still checks the ordinary sibling's sent history",
       ctx do
    delivery =
      Fixtures.message(
        id: "digest",
        labels: ["SENT"],
        headers: [{"From", "janitor@emailjanitor.net"}, {"Message-ID", "<recorded@ses.example>"}]
      )

    Agent.update(
      ctx.state,
      &Map.merge(&1, %{
        messages: [delivery, Fixtures.message()],
        contacts: MapSet.new(["vendor.com"])
      })
    )

    config = %{
      ctx.config
      | self_mail: fn headers -> {:ok, {"Message-ID", "<recorded@ses.example>"} in headers} end
    }

    assert {:ok, %{status: :kept}} = Worker.step(config)
    assert read(ctx.state).model_inputs == [] and read(ctx.state).mutations == []
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

  test "failed watch renewal backs off independently while periodic history cleanup continues",
       ctx do
    Agent.update(ctx.state, &%{&1 | arrivals: %{}})
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    {:ok, original} = Ingestion.checkpoint(ctx.scope, ctx.box.id)
    advance(ctx.clock, 43_201)
    Agent.update(ctx.state, &%{&1 | arrivals: %{"100" => %{through: "101", ids: ["message-1"]}}})
    config = %{ctx.config | gmail: {Gmail, [state: ctx.state, renew_error: :forbidden]}}

    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).mutations == [["message-1"]]

    assert [%EmailJanitor.Worker.Watch{attempts: 1, next_attempt_at: %DateTime{}}] =
             Repo.all(EmailJanitor.Worker.Watch, prefix: ctx.scope.prefix)

    assert {:ok, %{status: :idle}} = Worker.step(config)
    assert Enum.count(read(ctx.state).calls, &(&1 == :renew)) == 1

    advance(ctx.clock, 3_601)
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)

    assert [%EmailJanitor.Worker.Watch{attempts: 0, next_attempt_at: nil}] =
             Repo.all(EmailJanitor.Worker.Watch, prefix: ctx.scope.prefix)

    {:ok, current} = Ingestion.checkpoint(ctx.scope, ctx.box.id)

    assert current.generation == original.generation and
             current.baseline_id == original.baseline_id

    assert current.cursor == "101"
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

    assert {:ok, %{status: :done, more?: true}} = Worker.step(ctx.config)
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
    barrier = {__MODULE__, :disconnect_commit, make_ref()}

    :ok =
      :telemetry.attach(
        barrier,
        (Repo.config()[:telemetry_prefix] || [:email_janitor, :worker_test, :repo]) ++ [:query],
        &__MODULE__.await_disconnect_commit/4,
        %{key: barrier, owner: owner}
      )

    on_exit(fn -> :telemetry.detach(barrier) end)

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

          send(executor, {barrier, :committed})
          send(owner, :disconnected)
        end)

      receive do
        {:disconnect_backend, backend} ->
          await_blocked(backend, 100)
          Process.put(barrier, true)
      after
        2_000 -> flunk("disconnect task did not start")
      end
    end

    Agent.update(ctx.quota, &Map.put(&1, :reserve_hook, hook))
    assert {:ok, %{status: status}} = Worker.step(ctx.config)
    assert status == :deferred
    assert_receive :disconnected, 1_000
    assert_received {^barrier, :barrier_reached}
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

  test "pre-review failures defer the oldest arrival instead of starving newer threads", ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [
            Fixtures.message(id: "a-old", thread_id: "bad-thread"),
            Fixtures.message(id: "z-new", thread_id: "good-thread")
          ],
          arrivals: %{"100" => %{through: "101", ids: ["a-old", "z-new"]}}
      }
    )

    config = %{ctx.config | gmail: {Gmail, [state: ctx.state, thread_failures: ["bad-thread"]]}}
    assert {:ok, %{status: :deferred, more?: true}} = Worker.step(config)
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).mutations == [["z-new"]]
    assert {:ok, [%{message_id: "a-old"}]} = pending(ctx)
  end

  test "snapshot errors also release the queue for other due arrivals", ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [
            Fixtures.message(id: "a-old", thread_id: "bad-thread"),
            Fixtures.message(id: "z-new", thread_id: "good-thread")
          ],
          arrivals: %{"100" => %{through: "101", ids: ["a-old", "z-new"]}}
      }
    )

    config = %{ctx.config | gmail: {Gmail, [state: ctx.state, snapshot_failures: ["bad-thread"]]}}
    assert {:ok, %{status: :deferred, more?: true}} = Worker.step(config)
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).mutations == [["z-new"]]
  end

  test "seven pending siblings cannot bypass a transient review deferral", ctx do
    messages = Enum.map(1..7, &Fixtures.message(id: "arrival-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          model: :error,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    assert {:ok, %{status: :model_unavailable, more?: false}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == 1
    assert {:ok, %{status: :idle, more?: false}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == 1
    assert [%Deferral{message_ids: ids}] = Repo.all(Deferral, prefix: ctx.scope.prefix)
    assert length(ids) == 7
  end

  test "unsupported policy admission pauses stable content without repeated model calls", ctx do
    Agent.update(
      ctx.state,
      &%{&1 | messages: [Fixtures.message(id: "old-context"), Fixtures.message()]}
    )

    config = %{ctx.config | policy: %Policy{adapter: __MODULE__.LegacyPolicy, context: nil}}
    assert {:ok, %{status: :blocked}} = Worker.step(config)
    assert [%Deferral{status: :blocked}] = Repo.all(Deferral, prefix: ctx.scope.prefix)
    assert read(ctx.state).mutations == []
    advance(ctx.clock, 901)
    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert length(read(ctx.state).model_inputs) == 1
    assert {:ok, [_]} = pending(ctx)
  end

  test "invalid candidate output exponentially backs off then waits for explicit requeue", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    assert {:ok, 1} = Worker.queue_backlog(ctx.scope, ctx.box)
    Agent.update(ctx.state, &%{&1 | model: :invalid})

    for attempt <- 1..8 do
      assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

      assert [%Candidate{attempts: ^attempt, requested: requested}] =
               Repo.all(Candidate, prefix: ctx.scope.prefix)

      assert requested == attempt < 8
      advance(ctx.clock, 901)
    end

    count = length(read(ctx.state).model_inputs)
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == count
    assert {:ok, 0} = Worker.queue_backlog(ctx.scope, ctx.box)
    [%Candidate{candidate_id: id}] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, id)

    assert [%Candidate{attempts: 0, requested: true}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)
  end

  test "deterministic late correspondence guard is processed without repeating classification",
       ctx do
    hook = fn -> Agent.update(ctx.state, &Map.put(&1, :contacts, MapSet.new(["vendor.com"]))) end
    config = %{ctx.config | classifier: {Classifier, [state: ctx.state, after_model: hook]}}
    assert {:ok, %{status: :skipped}} = Worker.step(config)
    assert read(ctx.state).mutations == []
    assert {:ok, []} = pending(ctx)
    assert {:ok, %{status: :idle}} = Worker.step(config)
    assert length(read(ctx.state).model_inputs) == 1
  end

  test "invalid arrival decisions stop model retries after eight unchanged attempts", ctx do
    Agent.update(ctx.state, &%{&1 | model: :invalid})

    for _ <- 1..8 do
      assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
      advance(ctx.clock, 901)
    end

    assert [%Deferral{status: :blocked}] = Repo.all(Deferral, prefix: ctx.scope.prefix)
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == 8
    assert {:ok, [_]} = pending(ctx)
  end

  test "real scheduler passes two unreadable siblings and cleans a newer healthy thread", ctx do
    observer = self()

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [
            Fixtures.message(id: "a-old-1", thread_id: "bad-thread"),
            Fixtures.message(id: "a-old-2", thread_id: "bad-thread"),
            Fixtures.message(id: "z-new", thread_id: "good-thread")
          ],
          arrivals: %{"100" => %{through: "101", ids: ["a-old-1", "a-old-2", "z-new"]}}
      }
    )

    config = %{
      ctx.config
      | gmail: {Gmail, [state: ctx.state, thread_failures: ["bad-thread"]]},
        report: fn status ->
          send(observer, {:reported_worker_status, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted-inbox"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    assert_receive {:reported_worker_status, :done}, 2_000
    assert read(ctx.state).mutations == [["z-new"]]

    assert [%Deferral{status: :unreadable, message_ids: ["a-old-1", "a-old-2"]}] =
             Repo.all(Deferral, prefix: ctx.scope.prefix)

    assert {:ok, pending} = pending(ctx)
    assert Enum.sort(Enum.map(pending, & &1.message_id)) == ["a-old-1", "a-old-2"]
    before = Enum.count(read(ctx.state).calls, &(&1 == :full_thread))
    advance(ctx.clock, 901)
    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert Enum.count(read(ctx.state).calls, &(&1 == :full_thread)) == before
  end

  test "real scheduler unions malformed snapshot siblings instead of alternating IDs",
       ctx do
    observer = self()

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [
            Fixtures.message(id: "a-old-1", thread_id: "bad-thread"),
            Fixtures.message(id: "a-old-2", thread_id: "bad-thread"),
            Fixtures.message(id: "z-new", thread_id: "good-thread")
          ],
          arrivals: %{"100" => %{through: "101", ids: ["a-old-1", "a-old-2", "z-new"]}}
      }
    )

    config = %{
      ctx.config
      | gmail: {Gmail, [state: ctx.state, snapshot_failures: ["bad-thread"]]},
        report: fn status ->
          send(observer, {:reported_worker_status, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted-inbox"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    assert_receive {:reported_worker_status, :done}, 2_000
    assert read(ctx.state).mutations == [["z-new"]]

    assert [%Deferral{status: :unreadable, message_ids: ["a-old-1", "a-old-2"]}] =
             Repo.all(Deferral, prefix: ctx.scope.prefix)

    assert {:ok, pending} = pending(ctx)
    assert Enum.sort(Enum.map(pending, & &1.message_id)) == ["a-old-1", "a-old-2"]
    before = Enum.count(read(ctx.state).calls, &(&1 == :full_thread))
    advance(ctx.clock, 901)
    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert Enum.count(read(ctx.state).calls, &(&1 == :full_thread)) == before
  end

  test "unrelated arrival outages do not count toward the eight invalid-decision limit", ctx do
    Agent.update(ctx.state, &%{&1 | model: :error})

    for _ <- 1..7 do
      assert {:ok, %{status: :model_unavailable}} = Worker.step(ctx.config)
      advance(ctx.clock, 901)
    end

    Agent.update(ctx.state, &%{&1 | model: :invalid})
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

    assert [%Deferral{status: :invalid, attempts: 1}] =
             Repo.all(Deferral, prefix: ctx.scope.prefix)
  end

  test "unrelated candidate outages have a separate invalid-decision counter", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    assert {:ok, 1} = Worker.queue_backlog(ctx.scope, ctx.box)
    Agent.update(ctx.state, &%{&1 | model: :error})

    for _ <- 1..7 do
      assert {:ok, %{status: :model_unavailable}} = Worker.step(ctx.config)
      advance(ctx.clock, 901)
    end

    Agent.update(ctx.state, &%{&1 | model: :invalid})
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

    assert [%Candidate{requested: true, attempts: 8, invalid_attempts: 1}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)
  end

  test "real scheduler passes thread-specific model rejection without delaying healthy mail",
       ctx do
    observer = self()

    messages =
      Enum.map(1..3, &Fixtures.message(id: "bad-#{&1}", thread_id: "bad-thread-#{&1}")) ++
        [Fixtures.message(id: "z-new", thread_id: "healthy-thread")]

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    config = %{
      ctx.config
      | classifier:
          {Classifier, [state: ctx.state, failed_threads: Enum.map(1..3, &"bad-thread-#{&1}")]},
        report: fn status ->
          send(observer, {:reported_model_step, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted-inbox"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    assert_receive {:reported_model_step, :done}, 2_000
    assert read(ctx.state).mutations == [["z-new"]]
    assert {:ok, pending} = pending(ctx)
    assert Enum.sort(Enum.map(pending, & &1.message_id)) == ["bad-1", "bad-2", "bad-3"]
    assert length(read(ctx.state).model_inputs) == 4
  end

  test "global model outage backs off instead of bursting through several due threads", ctx do
    observer = self()
    messages = Enum.map(1..4, &Fixtures.message(id: "arrival-#{&1}", thread_id: "thread-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          model: :error,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    config = %{
      ctx.config
      | report: fn status ->
          send(observer, {:global_outcome, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    assert_receive {:global_outcome, :model_unavailable}, 1_000
    refute_receive {:global_outcome, _}, 250
    assert length(read(ctx.state).model_inputs) == 1
    assert read(ctx.state).mutations == []
  end

  test "local content rejection reports its fixed reason while scheduling other mail", ctx do
    observer = self()
    Agent.update(ctx.state, &%{&1 | model: :rejected})

    config = %{
      ctx.config
      | report: fn status ->
          send(observer, {:reported, status})
          :ok
        end
    }

    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert_receive {:reported, :model_rejected}
    assert {:ok, [_]} = pending(ctx)
    assert read(ctx.state).mutations == []
  end

  test "bulk host requeue preserves requested candidate backoff and invalid cap", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    assert {:ok, 1} = Worker.queue_backlog(ctx.scope, ctx.box)
    Agent.update(ctx.state, &%{&1 | model: :error})
    assert {:ok, %{status: :model_unavailable}} = Worker.step(ctx.config)
    [before] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    assert before.attempts == 1 and before.requested
    for _ <- 1..5, do: assert({:ok, 0} == Worker.queue_backlog(ctx.scope, ctx.box))
    [after_bulk] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    assert after_bulk.attempts == before.attempts
    assert after_bulk.next_attempt_at == before.next_attempt_at
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == 2
    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, before.candidate_id)

    assert [%Candidate{attempts: 0, requested: true, next_attempt_at: nil}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)
  end

  test "attempt ordering gives a new healthy arrival priority over a due failed retry", ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [
            Fixtures.message(id: "a-old", thread_id: "bad-thread"),
            Fixtures.message(id: "z-new", thread_id: "healthy-thread")
          ],
          arrivals: %{"100" => %{through: "101", ids: ["a-old", "z-new"]}}
      }
    )

    config = %{ctx.config | gmail: {Gmail, [state: ctx.state, snapshot_outages: ["bad-thread"]]}}
    assert {:ok, %{status: :gmail_unavailable}} = Worker.step(config)
    advance(ctx.clock, 61)
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).mutations == [["z-new"]]
  end

  test "quota adapter outages back off arrivals after one model call", ctx do
    observer = self()
    messages = Enum.map(1..4, &Fixtures.message(id: "arrival-#{&1}", thread_id: "thread-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    Agent.update(ctx.quota, &Map.put(&1, :reserve_error, true))

    config = %{
      ctx.config
      | report: fn status ->
          send(observer, {:policy_outcome, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    assert_receive {:policy_outcome, :policy_unavailable}, 1_000
    refute_receive {:policy_outcome, _}, 250
    assert length(read(ctx.state).model_inputs) == 1
    assert read(ctx.state).mutations == []
  end

  test "quota adapter outages also back off requested candidates", ctx do
    observer = self()
    messages = Enum.map(1..3, &Fixtures.message(id: "arrival-#{&1}", thread_id: "thread-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    Agent.update(ctx.quota, &%{&1 | block: :cap})
    for _ <- 1..3, do: assert({:ok, %{status: :blocked}} = Worker.step(ctx.config))
    assert {:ok, 3} = Worker.queue_backlog(ctx.scope, ctx.box)
    Agent.update(ctx.quota, &Map.put(%{&1 | block: nil}, :reserve_error, true))

    config = %{
      ctx.config
      | report: fn status ->
          send(observer, {:candidate_policy, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    assert_receive {:candidate_policy, :policy_unavailable}, 1_000
    refute_receive {:candidate_policy, _}, 250
    assert length(read(ctx.state).model_inputs) == 4
    assert read(ctx.state).mutations == []
  end

  test "four distinct failed model conversations trip inbox backoff", ctx do
    observer = self()
    messages = Enum.map(1..7, &Fixtures.message(id: "arrival-#{&1}", thread_id: "thread-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          model: :rejected,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    config = %{
      ctx.config
      | report: fn status ->
          send(observer, {:rejection_report, status})
          :ok
        end
    }

    start_supervised!(
      {EmailJanitor.Worker.Server,
       list: fn -> {:ok, ["trusted"]} end,
       resolve: fn _ -> {:ok, config} end,
       interval_ms: 5_000,
       max_concurrency: 1}
    )

    for _ <- 1..4, do: assert_receive({:rejection_report, :model_rejected}, 1_500)
    refute_receive {:rejection_report, _}, 250
    assert length(read(ctx.state).model_inputs) == 4
    assert read(ctx.state).mutations == []

    assert [%{bad_threads: threads}] =
             Repo.all(EmailJanitor.Worker.ModelStreak, prefix: ctx.scope.prefix)

    assert length(threads) == 4
  end

  test "successful classification resets the distinct rejected-conversation streak", ctx do
    messages = Enum.map(1..5, &Fixtures.message(id: "arrival-#{&1}", thread_id: "thread-#{&1}"))

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: messages,
          model: :rejected,
          arrivals: %{"100" => %{through: "101", ids: Enum.map(messages, fn m -> m.id end)}}
      }
    )

    for _ <- 1..3, do: assert({:ok, %{status: :deferred}} = Worker.step(ctx.config))
    Agent.update(ctx.state, &%{&1 | model: :done})
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert Repo.all(EmailJanitor.Worker.ModelStreak, prefix: ctx.scope.prefix) == []
    Agent.update(ctx.state, &%{&1 | model: :rejected})
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

    assert [%{bad_threads: [_]}] =
             Repo.all(EmailJanitor.Worker.ModelStreak, prefix: ctx.scope.prefix)
  end

  test "unchanged content stops model rejection retries after four attempts", ctx do
    Agent.update(ctx.state, &%{&1 | model: :rejected})

    for _ <- 1..4 do
      assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
      advance(ctx.clock, 901)
    end

    assert [%Deferral{status: :blocked}] = Repo.all(Deferral, prefix: ctx.scope.prefix)
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)
    assert length(read(ctx.state).model_inputs) == 4

    Repo.update_all(EmailJanitor.Store.Mailbox, [set: [instruction_version: 2]],
      prefix: ctx.scope.prefix,
      log: false
    )

    Agent.update(ctx.state, &%{&1 | model: :done})
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
  end

  test "candidate rejection cap survives repeated bulk discovery until explicit repair", ctx do
    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    assert {:ok, 1} = Worker.queue_backlog(ctx.scope, ctx.box)
    Agent.update(ctx.state, &%{&1 | model: :rejected})

    for count <- 1..4 do
      assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

      assert [%Candidate{rejected_attempts: ^count}] =
               Repo.all(Candidate, prefix: ctx.scope.prefix)

      advance(ctx.clock, 901)
    end

    assert {:ok, 0} = Worker.queue_backlog(ctx.scope, ctx.box)
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    [%Candidate{candidate_id: id}] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, id)

    assert [%Candidate{rejected_attempts: 0, requested: true}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)
  end

  test "partial Keep retires exact worker and host metadata without withdrawing its sibling",
       ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [Fixtures.message(), Fixtures.message(id: "message-2")],
          arrivals: %{"100" => %{through: "101", ids: ["message-1", "message-2"]}}
      }
    )

    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    Agent.update(ctx.state, &%{&1 | model: :keep})

    assert {:keep, :classifier_kept} =
             EmailJanitor.Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               ctx.config.gmail,
               ctx.config.classifier,
               "Synthetic instructions",
               1,
               cleanup_target_ids: ["message-1"],
               policy: %Policy{adapter: EmailJanitor.Worker.Gate, context: %{config: ctx.config}}
             )

    assert [%Candidate{message_ids: ["message-2"]}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert [%{remaining_message_ids: ["message-2"]}] =
             Repo.all(EmailJanitor.Store.Candidate, prefix: ctx.scope.prefix)

    assert {:retire_exact, ["message-1"]} in read(ctx.quota).calls
    refute {:retire_whole, ["message-1"]} in read(ctx.quota).calls
    assert read(ctx.state).mutations == []
  end

  test "Gate never sends a partial retirement to a whole-only host callback", ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [Fixtures.message(), Fixtures.message(id: "message-2")],
          arrivals: %{"100" => %{through: "101", ids: ["message-1", "message-2"]}}
      }
    )

    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    Agent.update(ctx.state, &%{&1 | model: :keep})
    config = %{ctx.config | policy: %Policy{adapter: __MODULE__.WholeOnlyPolicy, context: self()}}

    assert {:error, :partial_retirement_unsupported} =
             EmailJanitor.Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               config.gmail,
               config.classifier,
               "Synthetic instructions",
               1,
               cleanup_target_ids: ["message-1"],
               policy: %Policy{adapter: EmailJanitor.Worker.Gate, context: %{config: config}}
             )

    refute_received {:legacy_whole_retired, _}
    assert [%Candidate{message_ids: ids}] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    assert ids == ["message-1", "message-2"]

    assert [%{remaining_message_ids: remaining}] =
             Repo.all(EmailJanitor.Store.Candidate, prefix: ctx.scope.prefix)

    assert remaining == ids
    assert read(ctx.state).mutations == []
  end

  test "unsupported partial retirement pauses arrival work instead of retrying its classifier",
       ctx do
    two = [Fixtures.message(), Fixtures.message(id: "message-2")]

    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: two,
          arrivals: %{"100" => %{through: "101", ids: ["message-1", "message-2"]}}
      }
    )

    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)

    Agent.update(ctx.state, fn state ->
      messages = [
        Fixtures.message(labels: ["UNREAD"]),
        Fixtures.message(id: "message-2"),
        Fixtures.message(id: "message-3")
      ]

      %{
        state
        | messages: messages,
          model: :keep,
          revision: "revision-2",
          arrivals: %{"101" => %{through: "102", ids: ["message-3"]}}
      }
    end)

    owner = self()

    config = %{
      ctx.config
      | report: &send(owner, {:report, &1}),
        policy: %Policy{adapter: __MODULE__.WholeOnlyPolicy, context: owner}
    }

    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert_received {:report, :partial_retirement_unsupported}
    assert [%Deferral{status: :blocked}] = Repo.all(Deferral, prefix: ctx.scope.prefix)
    before = read(ctx.state)
    advance(ctx.clock, 901)
    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert read(ctx.state).model_inputs == before.model_inputs

    assert Enum.count(read(ctx.state).calls, &(&1 == :full_thread)) ==
             Enum.count(before.calls, &(&1 == :full_thread))

    refute_received {:legacy_whole_retired, _}

    assert [%{remaining_message_ids: ["message-1", "message-2"]}] =
             Repo.all(EmailJanitor.Store.Candidate, prefix: ctx.scope.prefix)

    assert {:ok, [%{message_id: "message-3"}]} = pending(ctx)
  end

  test "manual prebaseline upgrade work requires an explicit scoped grant and retains old siblings",
       ctx do
    id = manual_candidate(ctx)
    assert Repo.all(Candidate, prefix: ctx.scope.prefix) == []
    assert {:ok, 0} = Worker.queue_backlog(ctx.scope, ctx.box)
    assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
    assert {:ok, []} = pending(ctx)
    owner = self()

    config = %{
      ctx.config
      | allow_manual_recheck: fn authority, ids ->
          send(owner, {:manual_proof, authority, ids})
          :ok
        end
    }

    Agent.update(ctx.quota, &%{&1 | block: nil})
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert_received {:manual_proof, ^id, ["message-1"]}
    assert read(ctx.state).mutations == [["message-1"]]
    [first, second] = read(ctx.state).messages
    assert first.labels == ["UNREAD", "IMPORTANT"]
    assert "INBOX" in second.labels
    assert {:ok, []} = pending(ctx)
  end

  test "manual grant absence and partial revocation fail closed before reading message bodies",
       ctx do
    id = manual_candidate(ctx)

    assert :ok =
             Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1", "message-2"])

    before = read(ctx.state)
    assert {:ok, %{status: :deferred}} = Worker.step(ctx.config)

    assert [%Candidate{contract_blocked: true, requested: false}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert read(ctx.state).calls == before.calls ++ [{:history, "100"}]
    assert read(ctx.state).model_inputs == before.model_inputs
    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, id)
    owner = self()

    config = %{
      ctx.config
      | allow_manual_recheck: fn authority, ids ->
          send(owner, {:grant_ids, authority, ids})
          if Enum.all?(ids, &(&1 == "message-2")), do: :ok, else: {:error, :withdrawn}
        end
    }

    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert_received {:grant_ids, ^id, ["message-1", "message-2"]}
    assert read(ctx.state).model_inputs == before.model_inputs
    assert read(ctx.state).mutations == []
    assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-2"])
    Agent.update(ctx.quota, &%{&1 | block: nil})
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert read(ctx.state).mutations == [["message-2"]]
  end

  test "manual authority is checked again inside final admission after classification", ctx do
    id = manual_candidate(ctx)
    assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
    grant = start_supervised!({Agent, fn -> true end}, id: :manual_grant)

    config = %{
      ctx.config
      | classifier:
          {Classifier,
           [state: ctx.state, after_model: fn -> Agent.update(grant, fn _ -> false end) end]},
        allow_manual_recheck: fn _, _ ->
          if Agent.get(grant, & &1), do: :ok, else: {:error, :withdrawn}
        end
    }

    Agent.update(ctx.quota, &%{&1 | block: nil})
    reservations = read(ctx.quota).calls
    assert {:ok, %{status: :deferred}} = Worker.step(config)
    assert read(ctx.quota).calls == reservations
    assert read(ctx.state).mutations == []
    assert Repo.all(Action, prefix: ctx.scope.prefix) == []
  end

  test "manual queuing validates scope, exact pending IDs and stable authority without reviving retries",
       ctx do
    id = manual_candidate(ctx)
    authority = Ecto.UUID.generate()

    assert {:error, :ineligible_recheck} =
             Worker.queue_manual(ctx.scope, ctx.box, Ecto.UUID.generate(), "thread-1", [
               "message-1"
             ])

    assert {:error, :ineligible_recheck} =
             Worker.queue_manual(ctx.scope, ctx.box, id, "wrong-thread", ["message-1"])

    assert {:error, :ineligible_recheck} =
             Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["unrelated-id"])

    wrong_box = %{ctx.box | address: "somebody@else.example"}

    assert {:error, :ineligible_recheck} =
             Worker.queue_manual(ctx.scope, wrong_box, id, "thread-1", ["message-1"])

    assert :ok =
             Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"],
               authority_id: authority
             )

    config = %{ctx.config | allow_manual_recheck: fn ^authority, ["message-1"] -> :ok end}
    Agent.update(ctx.state, &%{&1 | model: :error})
    assert {:ok, %{status: :model_unavailable}} = Worker.step(config)
    [before] = Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert :ok =
             Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"],
               authority_id: authority
             )

    assert [^before] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    assert {:ok, 0} = Worker.queue_backlog(ctx.scope, ctx.box)

    assert {:error, :ineligible_recheck} =
             Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])

    Repo.update!(Ecto.Changeset.change(before, requested: false, invalid_attempts: 8),
      prefix: ctx.scope.prefix
    )

    assert :ok =
             Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"],
               authority_id: authority
             )

    assert [%Candidate{requested: false, invalid_attempts: 8}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, id)

    assert [%Candidate{requested: true, invalid_attempts: 0}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)
  end

  test "a manual cancelled action carries original authority across reconnect and fresh admission",
       ctx do
    id = manual_candidate(ctx)
    assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
    owner = self()

    config = %{
      ctx.config
      | allow_manual_recheck: fn authority, ids ->
          send(owner, {:manual_proof, authority, ids})
          :ok
        end
    }

    Agent.update(ctx.quota, &%{&1 | block: nil})

    Agent.update(
      ctx.quota,
      &Map.put(&1, :reserve_hook, fn ->
        Repo.update_all(EmailJanitor.Store.Mailbox, [inc: [instruction_version: 1]],
          prefix: ctx.scope.prefix,
          log: false
        )
      end)
    )

    assert {:ok, %{status: :deferred}} = Worker.step(config)

    assert [%Action{state: :cancelled, dispatch_started_at: nil, id: cancelled_id}] =
             Repo.all(Action, prefix: ctx.scope.prefix)

    assert %Candidate{source_kind: :manual, authority_id: ^id} =
             Repo.get_by!(Candidate, [candidate_id: cancelled_id], prefix: ctx.scope.prefix)

    assert {:ok, previous} = Ingestion.checkpoint(ctx.scope, ctx.box.id)

    assert {:ok, _} =
             Ingestion.reconnect(ctx.scope, ctx.box, previous.generation, %{
               history_id: "500",
               expires_at: DateTime.add(DateTime.utc_now(), 604_800)
             })

    Agent.update(ctx.quota, &Map.delete(&1, :reserve_hook))
    assert {:ok, _} = Worker.queue_backlog(ctx.scope, ctx.box)
    advance(ctx.clock, 901)
    assert {:ok, %{status: :done}} = Worker.step(config)
    assert_received {:manual_proof, ^id, ["message-1"]}
    assert read(ctx.state).mutations == [["message-1"]]
  end

  test "unsupported manual partial retirement remains paused across ordinary upgrade discovery",
       ctx do
    id = manual_candidate(ctx)
    assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
    Agent.update(ctx.state, &%{&1 | model: :keep})
    owner = self()

    config = %{
      ctx.config
      | allow_manual_recheck: fn _, _ -> :ok end,
        policy: %Policy{adapter: __MODULE__.WholeOnlyPolicy, context: owner}
    }

    assert {:ok, %{status: :deferred}} = Worker.step(config)

    assert [%Candidate{contract_blocked: true, requested: false}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert {:ok, 0} = Worker.queue_backlog(ctx.scope, ctx.box)
    assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
    before = read(ctx.state)
    advance(ctx.clock, 901)
    assert {:ok, %{status: :idle}} = Worker.step(config)
    assert read(ctx.state).model_inputs == before.model_inputs
    refute_received {:legacy_whole_retired, _}

    assert [%{remaining_message_ids: ["message-1", "message-2"]}] =
             Repo.all(EmailJanitor.Store.Candidate, prefix: ctx.scope.prefix)

    assert :ok = Worker.queue_recheck(ctx.scope, ctx.box, id)

    assert [%Candidate{contract_blocked: false, requested: true}] =
             Repo.all(Candidate, prefix: ctx.scope.prefix)
  end

  test "a settled covering action retires only its confirmed arrival IDs so uncovered work progresses",
       ctx do
    assert {:ok, proposal} =
             EmailJanitor.Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               ctx.config.gmail,
               ctx.config.classifier,
               "Synthetic instructions",
               1,
               cleanup_target_ids: ["message-1"]
             )

    assert {:done, _} =
             EmailJanitor.Executor.execute(ctx.scope, ctx.box, proposal, ctx.config.gmail,
               policy: ctx.config.policy
             )

    # Simulate an external label move; a new history batch still includes B.
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [Fixtures.message(), Fixtures.message(id: "message-2")],
          arrivals: %{"100" => %{through: "101", ids: ["message-1", "message-2"]}}
      }
    )

    Agent.update(ctx.quota, &%{&1 | failures: 10})
    assert {:ok, %{status: :policy_unavailable}} = Worker.step(ctx.config)
    assert {:ok, [%{message_id: "message-2"}]} = pending(ctx)
    assert read(ctx.state).mutations == [["message-1"]]
    Agent.update(ctx.quota, &%{&1 | failures: 0})
    advance(ctx.clock, 901)
    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == [["message-1"], ["message-2"]]
    assert {:ok, []} = pending(ctx)
    [covered, new] = read(ctx.state).messages
    assert "INBOX" in covered.labels
    refute "INBOX" in new.labels
  end

  for reason <- [
        :invalid_thread,
        :invalid_message,
        :invalid_mime,
        :invalid_headers,
        :invalid_date
      ] do
    test "unreadable #{reason} manual/backlog threads use metadata probes and do not block healthy arrivals",
         ctx do
      id = manual_candidate(ctx)
      assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
      Agent.update(ctx.quota, &%{&1 | block: nil})

      Agent.update(
        ctx.state,
        &%{
          &1
          | messages: &1.messages ++ [Fixtures.message(id: "healthy", thread_id: "thread-2")],
            arrivals: %{"100" => %{through: "101", ids: ["healthy"]}}
        }
      )

      config = %{
        ctx.config
        | allow_manual_recheck: fn _, _ -> :ok end,
          gmail:
            {Gmail,
             [state: ctx.state, thread_failures: ["thread-1"], thread_error: unquote(reason)]}
      }

      before = read(ctx.state)
      assert {:ok, %{status: :deferred}} = Worker.step(config)
      assert read(ctx.state).model_inputs == before.model_inputs
      assert [%Deferral{status: :unreadable}] = Repo.all(Deferral, prefix: ctx.scope.prefix)
      assert {:ok, %{status: :done}} = Worker.step(config)
      assert read(ctx.state).mutations == [["healthy"]]
      before = read(ctx.state)
      advance(ctx.clock, 901)
      assert {:ok, %{status: :deferred}} = Worker.step(config)
      assert read(ctx.state).model_inputs == before.model_inputs

      assert Enum.count(read(ctx.state).calls, &(&1 == :full_thread)) ==
               Enum.count(before.calls, &(&1 == :full_thread))

      Agent.update(ctx.state, &%{&1 | revision: "revision-repaired"})
      advance(ctx.clock, 901)
      assert {:ok, %{status: :done}} = Worker.step(%{config | gmail: ctx.config.gmail})
      assert read(ctx.state).mutations == [["healthy"], ["message-1"]]
    end
  end

  for mode <- [:keep, :invalid] do
    test "a concurrent manual selection change survives stale #{mode} completion", ctx do
      mode = unquote(mode)
      id = manual_candidate(ctx)
      assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
      Agent.update(ctx.state, &%{&1 | model: mode})
      [candidate] = Repo.all(Candidate, prefix: ctx.scope.prefix)

      Repo.update!(Ecto.Changeset.change(candidate, invalid_attempts: 7),
        prefix: ctx.scope.prefix
      )

      owner = self()

      config = %{
        ctx.config
        | allow_manual_recheck: fn _, _ -> :ok end,
          classifier:
            {Classifier,
             [
               state: ctx.state,
               after_model: fn ->
                 send(owner, {:classification_paused, self()})

                 receive do
                   :continue -> :ok
                 after
                   2_000 -> flunk("classification not released")
                 end
               end
             ]}
      }

      task = Task.async(fn -> Worker.step(config) end)
      assert_receive {:classification_paused, model}, 2_000

      assert :ok =
               Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1", "message-2"])

      send(model, :continue)
      assert {:ok, _} = Task.await(task)

      assert [
               %Candidate{
                 requested: true,
                 invalid_attempts: 0,
                 contract_blocked: false,
                 message_ids: ids
               }
             ] =
               Repo.all(Candidate, prefix: ctx.scope.prefix)

      assert "message-2" in ids
      if unquote(mode == :keep), do: assert(ids == ["message-2"])
      Agent.update(ctx.state, &%{&1 | model: :done})
      Agent.update(ctx.quota, &%{&1 | block: nil})
      assert {:ok, %{status: :done}} = Worker.step(%{config | classifier: ctx.config.classifier})
      assert List.last(read(ctx.state).mutations) == ids
    end
  end

  for {refusal, status, paused} <- [
        {:withdrawn, :deferred, true},
        {:upgrade, :blocked, false},
        {:outage, :policy_unavailable, false}
      ] do
    test "final admission preserves #{refusal} proof result after Gmail refetch", ctx do
      refusal = unquote(refusal)
      expected_status = unquote(status)
      paused = unquote(paused)
      id = manual_candidate(ctx)
      assert :ok = Worker.queue_manual(ctx.scope, ctx.box, id, "thread-1", ["message-1"])
      grant = start_supervised!({Agent, fn -> :valid end}, id: :late_grant)

      callback = fn _, _ ->
        case Agent.get(grant, & &1) do
          :valid -> :ok
          :withdrawn -> {:error, :withdrawn}
          :upgrade -> {:blocked, :upgrade_required}
          :outage -> {:error, :policy_unavailable}
        end
      end

      config = %{
        ctx.config
        | allow_manual_recheck: callback,
          gmail:
            {Gmail,
             [state: ctx.state, history_hook: fn -> Agent.update(grant, fn _ -> refusal end) end]}
      }

      before = read(ctx.quota).calls
      assert {:ok, %{status: ^expected_status}} = Worker.step(config)
      refute (read(ctx.quota).calls -- before) |> Enum.any?(&match?({:reserve, _}, &1))
      old = Repo.get_by!(Candidate, [candidate_id: id], prefix: ctx.scope.prefix)
      assert old.contract_blocked == paused
      assert read(ctx.state).mutations == []

      if unquote(refusal == :upgrade) do
        # The new blocked subset also keeps its original manual authority.
        assert Enum.any?(
                 Repo.all(Candidate, prefix: ctx.scope.prefix),
                 &(&1.authority_id == id and &1.message_ids == ["message-1"] and
                     &1.status == :pending)
               )
      end
    end
  end

  test "arrival generation changed at final admission is a connection change, never a policy outage",
       ctx do
    config = %{
      ctx.config
      | gmail:
          {Gmail,
           [
             state: ctx.state,
             history_hook: fn ->
               {:ok, cp} = Ingestion.checkpoint(ctx.scope, ctx.box.id)

               assert {:ok, _} =
                        Ingestion.reconnect(ctx.scope, ctx.box, cp.generation, %{
                          history_id: "500",
                          expires_at: DateTime.add(DateTime.utc_now(), 604_800)
                        })
             end
           ]}
    }

    assert {:ok, %{status: :connection_changed}} = Worker.step(config)
    assert read(ctx.state).mutations == []
    assert read(ctx.quota).calls == []
    assert Repo.all(Action, prefix: ctx.scope.prefix) == []
  end

  test "manual subsets cannot silently activate a wider existing arrival candidate", ctx do
    Agent.update(
      ctx.state,
      &%{
        &1
        | messages: [Fixtures.message(), Fixtures.message(id: "message-2")],
          arrivals: %{"100" => %{through: "101", ids: ["message-1", "message-2"]}}
      }
    )

    Agent.update(ctx.quota, &%{&1 | block: :cap})
    assert {:ok, %{status: :blocked}} = Worker.step(ctx.config)
    [candidate] = Repo.all(Candidate, prefix: ctx.scope.prefix)

    assert {:error, :ineligible_recheck} =
             Worker.queue_manual(ctx.scope, ctx.box, candidate.candidate_id, "thread-1", [
               "message-1"
             ])

    assert [^candidate] = Repo.all(Candidate, prefix: ctx.scope.prefix)
    Agent.update(ctx.quota, &%{&1 | block: nil})
    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == []
    assert Enum.all?(read(ctx.state).messages, &("INBOX" in &1.labels))

    assert :ok =
             Worker.queue_manual(ctx.scope, ctx.box, candidate.candidate_id, "thread-1", [
               "message-1",
               "message-2"
             ])

    assert {:ok, %{status: :done}} = Worker.step(ctx.config)
    assert read(ctx.state).mutations == [["message-1", "message-2"]]
  end

  defp manual_candidate(ctx) do
    Agent.update(
      ctx.state,
      &%{&1 | arrivals: %{}, messages: [Fixtures.message(), Fixtures.message(id: "message-2")]}
    )

    assert {:ok, %{status: :idle}} = Worker.step(ctx.config)
    Agent.update(ctx.quota, &%{&1 | block: :cap})

    assert {:ok, proposal} =
             EmailJanitor.Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               ctx.config.gmail,
               ctx.config.classifier,
               "Synthetic instructions",
               1,
               policy: ctx.config.policy,
               cleanup_target_ids: ["message-1", "message-2"]
             )

    assert {:blocked, :cap} =
             EmailJanitor.Executor.execute(ctx.scope, ctx.box, proposal, ctx.config.gmail,
               policy: ctx.config.policy
             )

    Repo.one!(EmailJanitor.Store.Candidate, prefix: ctx.scope.prefix).id
  end

  # The disconnect is known committed before the final fence, independent of
  # scheduler timing or PostgreSQL lock-queue barging. No production test hook.
  def await_disconnect_commit(_, _, metadata, %{key: barrier, owner: owner}) do
    if Process.get(barrier) == true and String.downcase(metadata.query) == "commit" do
      Process.delete(barrier)
      send(owner, {barrier, :barrier_reached})

      receive do
        {^barrier, :committed} -> :ok
      after
        5_000 -> flunk("disconnect did not commit after admission")
      end
    end
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
