defmodule EmailJanitor.RestoreTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Content, Executor, Fixtures, Restore, Store}
  alias EmailJanitor.Restore.{Effect, Protection}
  alias EmailJanitor.Store.Scope
  alias __MODULE__.Repo

  setup_all do
    start_supervised!(
      {Repo,
       socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
       database: "emailjanitor_test",
       username: System.fetch_env!("USER"),
       port: 5432,
       pool_size: 10,
       timeout: 45_000,
       log: false}
    )

    :ok
  end

  setup do
    prefix = "ej_restore_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, scope} = Scope.new(Repo, prefix)
    :ok = Restore.install(scope)
    box = Fixtures.inbox()
    {:ok, _} = Store.add_inbox(scope, box)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             messages: [Fixtures.message(), Fixtures.message(id: "message-2")],
             contacted: [],
             calls: [],
             restores: [],
             mode: :ok
           }
         end}
      )

    gmail = {EmailJanitor.TestGmail, [state: state]}

    assert {:ok, proposal} =
             Executor.review(
               scope,
               box,
               "thread-1",
               gmail,
               {EmailJanitor.TestClassifier, []},
               "Synthetic instructions",
               1
             )

    assert {:done, action_id} = Executor.execute(scope, box, proposal, gmail)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, ~s|DROP SCHEMA "#{prefix}" CASCADE|, [], log: false)
    end)

    %{
      scope: scope,
      box: box,
      state: state,
      action_id: action_id,
      effect_id: Ecto.UUID.generate(),
      gmail: {__MODULE__.Gmail, [state: state]}
    }
  end

  defp restore(ctx, options \\ []),
    do:
      Restore.apply(
        ctx.scope,
        ctx.box,
        ctx.effect_id,
        ctx.action_id,
        ["message-1"],
        ctx.gmail,
        Keyword.merge(trusted_options(), options)
      )

  defp trusted_options, do: [authorize: fn -> :ok end, expected_instruction_version: 1]
  defp effects(ctx), do: Repo.all(Effect, prefix: ctx.scope.prefix)
  defp read(ctx), do: Agent.get(ctx.state, & &1)

  test "exact restoration protects IDs durably before wire and preserves sibling labels", ctx do
    owner = self()

    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         before_wire: fn ->
           assert Store.restored_ids(ctx.scope, ctx.box.id) == MapSet.new(["message-1"])
           assert [%Effect{state: :intent, dispatch_started_at: %DateTime{}}] = effects(ctx)
           send(owner, :protection_before_wire)
         end
       ]}

    assert :ok = Restore.install(ctx.scope)
    assert {:done, id} = restore(%{ctx | gmail: gmail})
    assert id == ctx.effect_id
    assert_received :protection_before_wire
    assert read(ctx).restores == [["message-1"]]
    [first, second] = read(ctx).messages
    assert Enum.sort(first.labels) == ["IMPORTANT", "INBOX", "UNREAD"]
    assert second.labels == ["UNREAD", "IMPORTANT"]
    assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).state == :done
    assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).restored_message_ids == ["message-1"]

    assert Repo.all(Protection, prefix: ctx.scope.prefix) |> Enum.map(& &1.message_id) == [
             "message-1"
           ]

    assert {:existing, :done, ^id} = restore(ctx)
    assert read(ctx).restores == [["message-1"]]
  end

  test "unconfirmed, duplicate, wrong-thread IDs and changed UUID bindings never mutate", ctx do
    assert {:error, :invalid_restore_selection} =
             Restore.apply(
               ctx.scope,
               ctx.box,
               ctx.effect_id,
               ctx.action_id,
               ["message-1", "message-1"],
               ctx.gmail,
               trusted_options()
             )

    assert {:error, :unconfirmed_suppression} =
             Restore.apply(
               ctx.scope,
               ctx.box,
               ctx.effect_id,
               ctx.action_id,
               ["not-janitor-applied"],
               ctx.gmail,
               trusted_options()
             )

    assert effects(ctx) == [] and read(ctx).restores == []
    assert {:done, _} = restore(ctx)

    assert {:error, :effect_conflict} =
             Restore.apply(
               ctx.scope,
               ctx.box,
               ctx.effect_id,
               ctx.action_id,
               ["message-2"],
               ctx.gmail,
               trusted_options()
             )

    assert read(ctx).restores == [["message-1"]]
  end

  test "wrong scoped account and disconnected authorization fail closed", ctx do
    wrong = %{ctx.box | address: "another@acme.com"}

    assert {:error, :wrong_inbox} =
             Restore.apply(
               ctx.scope,
               wrong,
               ctx.effect_id,
               ctx.action_id,
               ["message-1"],
               ctx.gmail,
               trusted_options()
             )

    assert {:error, :connection_changed} =
             restore(ctx, authorize: fn -> {:error, :disconnected} end)

    assert effects(ctx) == [] and read(ctx).restores == []
  end

  for mode <- [:ok, :timeout, {:rejected, :forbidden}] do
    test "duplicate restore #{inspect(mode)} rejects a stale mailbox binding before returning state",
         ctx do
      Agent.update(ctx.state, &%{&1 | mode: unquote(mode)})
      _ = restore(ctx)
      before = read(ctx).restores

      assert {:error, :wrong_inbox} =
               restore(%{ctx | box: %{ctx.box | address: "stale@example.com"}})

      assert read(ctx).restores == before
    end
  end

  test "host binding and mailbox version are checked after preparation and at final fence", ctx do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if value < 3, do: :ok, else: {:error, :disconnected}
    end

    assert {:error, :connection_changed} = restore(ctx, authorize: authorize)
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert read(ctx).restores == []
    assert MapSet.member?(Store.restored_ids(ctx.scope, ctx.box.id), "message-1")
    assert {:existing, :cancelled, _} = restore(ctx)

    new = %{
      ctx
      | effect_id: Ecto.UUID.generate(),
        gmail:
          {__MODULE__.Gmail,
           [
             state: ctx.state,
             on_prepare: fn ->
               Repo.update_all(EmailJanitor.Store.Mailbox, [inc: [instruction_version: 1]],
                 prefix: ctx.scope.prefix
               )
             end
           ]}
    }

    assert {:error, :instructions_changed} = restore(new)
    assert length(effects(ctx)) == 1
    assert read(ctx).restores == []
  end

  test "ambiguous provider failures and process death never auto-resend and retain protections",
       ctx do
    Agent.update(ctx.state, &%{&1 | mode: :timeout})
    assert {:unresolved, id} = restore(ctx)
    assert id == ctx.effect_id
    assert {:existing, :unresolved, ^id} = restore(ctx)
    assert read(ctx).restores == [["message-1"]]
    assert {:error, :restore_pending} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
    assert MapSet.member?(Store.restored_ids(ctx.scope, ctx.box.id), "message-1")

    second = %{
      ctx
      | effect_id: Ecto.UUID.generate(),
        gmail:
          {__MODULE__.Gmail,
           [state: ctx.state, before_wire: fn -> Process.exit(self(), :kill) end]}
    }

    assert {:unresolved, dead_id} =
             Restore.apply(
               second.scope,
               second.box,
               second.effect_id,
               second.action_id,
               ["message-2"],
               second.gmail,
               trusted_options()
             )

    assert {:existing, :unresolved, ^dead_id} =
             Restore.apply(
               second.scope,
               second.box,
               second.effect_id,
               second.action_id,
               ["message-2"],
               second.gmail,
               trusted_options()
             )

    assert Enum.sort(MapSet.to_list(Store.restored_ids(ctx.scope, ctx.box.id))) == [
             "message-1",
             "message-2"
           ]
  end

  test "concurrent same-UUID and overlapping new-UUID attempts cannot issue a second wire request",
       ctx do
    owner = self()

    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         before_wire: fn ->
           send(owner, {:dispatch_waiting, self()})

           receive do
             :continue -> :ok
           after
             2_000 -> flunk("wire task not released")
           end
         end
       ]}

    task = Task.async(fn -> restore(%{ctx | gmail: gmail}) end)
    assert_receive {:dispatch_waiting, worker}, 2_000
    assert {:existing, :intent, id} = restore(ctx)
    assert {:prepared, ^id} = Restore.outcome(ctx.scope, ctx.box, id)
    assert {:prepared, ^id} = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"])
    assert :none = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"], id)
    assert {:error, :restore_pending} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
    send(worker, :continue)
    assert {:done, _} = Task.await(task)
    assert read(ctx).restores == [["message-1"]]
    assert {:done, ^id} = Restore.outcome(ctx.scope, ctx.box, id)
    assert :none = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"])
  end

  test "post-wire DB contention has its own remaining owner budget", ctx do
    parent = self()

    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         before_wire: fn -> Process.sleep(15_100) end,
         after_wire: fn ->
           wire_owner = self()

           locker =
             spawn(fn ->
               Repo.transaction(fn ->
                 Ecto.Adapters.SQL.query!(
                   Repo,
                   ~s|SELECT id FROM "#{ctx.scope.prefix}".inboxes WHERE id = $1 FOR UPDATE|,
                   [ctx.box.id],
                   log: false
                 )

                 send(wire_owner, :mailbox_locked)
                 send(parent, {:mailbox_locked, self()})

                 receive do
                   :release -> :ok
                 after
                   45_000 -> :ok
                 end
               end)
             end)

           receive do
             :mailbox_locked -> :ok
           after
             5_000 -> Process.exit(locker, :kill)
           end
         end
       ]}

    task = Task.async(fn -> send(parent, {:restore_finished, restore(%{ctx | gmail: gmail})}) end)
    assert_receive {:mailbox_locked, locker}, 20_000
    on_exit(fn -> send(locker, :release) end)
    # Wire consumed 15s. Old code killed this owner at 30s while it was waiting
    # to record positive proof; the mutation-only watchdog must already be off.
    refute_receive {:restore_finished, _}, 16_000
    send(locker, :release)
    assert_receive {:restore_finished, {:done, id}}, 5_000
    assert id == ctx.effect_id
    Task.await(task)
    assert {:done, ^id} = Restore.outcome(ctx.scope, ctx.box, id)
    assert read(ctx).restores == [["message-1"]]
  end

  test "a dead no-wire owner cancels and allows only a fresh explicit effect UUID", ctx do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :dead_guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if value == 3, do: Process.exit(self(), :kill), else: :ok
    end

    assert {:error, :executor_unavailable} = restore(ctx, authorize: authorize)
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert {:existing, :cancelled, _} = restore(ctx)
    assert {:done, _} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
    assert read(ctx).restores == [["message-1"]]
  end

  test "recovery reports a marker committed after its initial unlocked snapshot", ctx do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :late_marker_guard)
    id = {__MODULE__, :late_marker, make_ref()}

    event =
      (Repo.config()[:telemetry_prefix] || [:email_janitor, :restore_test, :repo]) ++ [:query]

    :ok =
      :telemetry.attach(id, event, &__MODULE__.late_marker/4, %{id: id, caller: self(), ctx: ctx})

    on_exit(fn -> :telemetry.detach(id) end)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if value == 3, do: Process.exit(self(), :kill), else: :ok
    end

    assert {:unresolved, effect_id} = restore(ctx, authorize: authorize)
    assert_received :late_marker_committed
    assert effect_id == ctx.effect_id
    assert {:unresolved, ^effect_id} = Restore.outcome(ctx.scope, ctx.box, effect_id)
    assert read(ctx).restores == []
  end

  def late_marker(_, _, metadata, %{id: id, caller: caller, ctx: ctx}) do
    result = Map.get(metadata, :result)
    nonempty = match?({:ok, %Postgrex.Result{rows: [_ | _]}}, result)

    if self() == caller and nonempty and
         String.contains?(metadata.query, ~s|FROM "#{ctx.scope.prefix}"."restore_effects"|) do
      :telemetry.detach(id)
      # Model a delayed COMMIT becoming visible between the unlocked snapshot
      # and the cancellation fence. No Gmail request was made by the dead owner.
      Task.async(fn ->
        import Ecto.Query

        Repo.update_all(
          from(e in Effect, where: e.id == ^ctx.effect_id),
          [set: [dispatch_started_at: DateTime.utc_now()]],
          prefix: ctx.scope.prefix,
          log: false
        )
      end)
      |> Task.await()

      send(caller, :late_marker_committed)
    end
  end

  test "metadata outcomes distinguish absent, cancelled, positive and permanent ambiguous effects",
       ctx do
    assert :none = Restore.outcome(ctx.scope, ctx.box, ctx.effect_id)
    assert :none = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"])
    assert {:error, :invalid_restore_selection} = Restore.outcome(ctx.scope, ctx.box, "bad")
    assert {:error, :invalid_restore_selection} = Restore.overlap_outcome(ctx.scope, ctx.box, [])

    assert {:error, :wrong_inbox} =
             Restore.outcome(ctx.scope, %{ctx.box | address: "wrong@acme.com"}, ctx.effect_id)

    assert {:unresolved, id} = restore(ctx, on_restored: fn _, _ -> {:error, :retry} end)
    assert {:done, ^id} = Restore.outcome(ctx.scope, ctx.box, id)
    assert :none = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"])
    # A new explicit request may act after a completed wire even if old report
    # bookkeeping awaits retry. The same effect UUID remains DB-only.
    assert {:done, _} = restore(%{ctx | effect_id: Ecto.UUID.generate()})

    effect = Repo.get!(Effect, id, prefix: ctx.scope.prefix)

    Repo.update!(
      Ecto.Changeset.change(effect,
        applied_at: nil,
        state: :unresolved
      ),
      prefix: ctx.scope.prefix
    )

    assert {:unresolved, ^id} = Restore.outcome(ctx.scope, ctx.box, id)
    assert {:unresolved, ^id} = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"])

    effect = Repo.get!(Effect, id, prefix: ctx.scope.prefix)
    unknown = %{EmailJanitor.Owner.capture() | owner_runtime: "unknown-runtime", owner_host: nil}

    Repo.update!(
      Ecto.Changeset.change(
        effect,
        Map.merge(unknown, %{state: :intent, dispatch_started_at: nil})
      ),
      prefix: ctx.scope.prefix
    )

    assert {:unresolved, ^id} = Restore.outcome(ctx.scope, ctx.box, id)

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    effect = Repo.get!(Effect, id, prefix: ctx.scope.prefix)
    owner = %{EmailJanitor.Owner.capture() | owner_beam_pid: :erlang.term_to_binary(dead)}
    Repo.update!(Ecto.Changeset.change(effect, owner), prefix: ctx.scope.prefix)
    assert {:cancelled, ^id} = Restore.outcome(ctx.scope, ctx.box, id)
    assert :none = Restore.overlap_outcome(ctx.scope, ctx.box, ["message-1"])
    assert read(ctx).restores == [["message-1"], ["message-1"]]
  end

  test "expired budgets stop both before intent and after reservation without any mutation",
       ctx do
    gmail =
      {__MODULE__.Gmail,
       [
         state: ctx.state,
         on_prepare: fn ->
           Process.put(
             {EmailJanitor.Owner, :execution_deadline},
             System.monotonic_time(:millisecond)
           )
         end
       ]}

    assert {:error, :dispatch_window_exhausted} = restore(%{ctx | gmail: gmail})
    assert effects(ctx) == []
    counter = start_supervised!({Agent, fn -> 0 end}, id: :budget_guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if value == 3,
        do:
          Process.put(
            {EmailJanitor.Owner, :execution_deadline},
            System.monotonic_time(:millisecond)
          )

      :ok
    end

    assert {:error, :dispatch_window_exhausted} = restore(ctx, authorize: authorize)
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert read(ctx).restores == []
  end

  test "source action must belong to the exact scoped inbox and protections reach normal review",
       ctx do
    other = %{Fixtures.inbox("other@acme.com") | id: "inbox-2"}
    assert {:ok, _} = Store.add_inbox(ctx.scope, other)

    assert {:error, :unconfirmed_suppression} =
             Restore.apply(
               ctx.scope,
               other,
               ctx.effect_id,
               ctx.action_id,
               ["message-1"],
               ctx.gmail,
               trusted_options()
             )

    assert {:done, _} = restore(ctx)

    assert {:keep, :manually_restored} =
             Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               {EmailJanitor.TestGmail, [state: ctx.state]},
               {EmailJanitor.TestClassifier, [notify: self()]},
               "Synthetic instructions",
               1
             )

    refute_received {:classified, _, _}
  end

  test "a real disconnect queued behind reservation defeats the final restore fence", ctx do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end}, id: :disconnect_guard)

    authorize = fn ->
      value = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if value == 2 do
        caller = self()

        {:ok, _} =
          Task.start(fn ->
            Repo.transaction(fn ->
              %{rows: [[backend]]} =
                Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [], log: false)

              send(caller, {:disconnect_backend, backend})

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
            end)

            send(owner, :disconnected)
          end)

        receive do
          {:disconnect_backend, backend} -> await_blocked(backend, 200)
        after
          2_000 -> flunk("disconnect did not start")
        end
      end

      :ok
    end

    assert {:error, :instructions_changed} = restore(ctx, authorize: authorize)
    assert_receive :disconnected, 2_000
    assert [%Effect{state: :cancelled, dispatch_started_at: nil}] = effects(ctx)
    assert read(ctx).restores == []
    assert MapSet.member?(Store.restored_ids(ctx.scope, ctx.box.id), "message-1")
  end

  defp await_blocked(_, 0), do: flunk("disconnect did not queue behind mailbox reservation")

  defp await_blocked(backend, attempts) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT cardinality(pg_blocking_pids($1))", [backend],
        log: false
      )

    if count > 0,
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_blocked(backend, attempts - 1)
        )
  end

  test "missing host guards fail before provider work", ctx do
    gmail = {__MODULE__.Gmail, [state: ctx.state, on_prepare: fn -> flunk("no credentials") end]}

    assert {:error, :authorization_required} =
             Restore.apply(ctx.scope, ctx.box, ctx.effect_id, ctx.action_id, ["message-1"], gmail)

    assert {:error, :invalid_restore_selection} =
             Restore.apply(ctx.scope, ctx.box, ctx.effect_id, ctx.action_id, ["message-1"], gmail,
               authorize: fn -> flunk("missing version checked first") end
             )

    assert effects(ctx) == [] and read(ctx).restores == []

    assert {:error, :authorization_required} =
             Restore.settle(ctx.scope, ctx.box, ctx.effect_id, [])

    assert {:error, :invalid_restore_selection} =
             Restore.settle(ctx.scope, ctx.box, "not-a-uuid", trusted_options())
  end

  for reason <- [:authorization_required, :forbidden, :rate_limited, :unsafe_http_observers] do
    test "proven unapplied #{reason} rejection permits a fresh explicit request", ctx do
      reason = unquote(reason)
      Agent.update(ctx.state, &%{&1 | mode: {:rejected, reason}})
      assert {:error, ^reason} = restore(ctx)

      assert [%Effect{state: :cancelled, applied_at: nil, dispatch_started_at: %DateTime{}}] =
               effects(ctx)

      assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).restored_message_ids == []
      assert {:existing, :cancelled, _} = restore(ctx)
      assert read(ctx).restores == [["message-1"]]
      refute "INBOX" in hd(read(ctx).messages).labels
      Agent.update(ctx.state, &%{&1 | mode: :ok})
      assert {:done, _} = restore(%{ctx | effect_id: Ecto.UUID.generate()})
      assert read(ctx).restores == [["message-1"], ["message-1"]]
    end
  end

  test "positive wire proof survives callback failure and DB-only retry never resends", ctx do
    parent = self()

    failure = fn action, ids ->
      send(parent, {:settling, action, ids})
      assert Store.get(ctx.scope, ctx.box.id, action).restored_message_ids == ["message-1"]
      {:error, :synthetic_callback_failure}
    end

    assert {:unresolved, id} = restore(ctx, on_restored: failure)
    assert_receive {:settling, action, ["message-1"]}
    assert action == ctx.action_id
    assert [%Effect{state: :unresolved, applied_at: %DateTime{}}] = effects(ctx)
    assert {:ok, [^id]} = Restore.pending_settlements(ctx.scope, ctx.box)

    assert {:error, :wrong_inbox} =
             Restore.pending_settlements(ctx.scope, %{ctx.box | address: "stale@example.com"})

    assert {:error, :wrong_inbox} =
             Restore.settle(
               ctx.scope,
               %{ctx.box | address: "stale@example.com"},
               id,
               trusted_options()
             )

    assert {:error, :invalid_restore_selection} =
             Restore.pending_settlements(ctx.scope, ctx.box, 0)

    assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).state == :done

    assert {:existing, :done, ^id} =
             restore(ctx,
               on_restored: fn action, ids ->
                 assert action == ctx.action_id and ids == ["message-1"]
                 :ok
               end
             )

    assert read(ctx).restores == [["message-1"]]
    assert {:ok, []} = Restore.pending_settlements(ctx.scope, ctx.box)
    assert {:done, ^id} = Restore.settle(ctx.scope, ctx.box, id, trusted_options())
    assert read(ctx).restores == [["message-1"]]
  end

  test "DB-only settle retries a persisted positive result after its owner exits", ctx do
    assert {:unresolved, id} =
             restore(ctx, on_restored: fn _, _ -> raise "PRIVATE_CALLBACK_FAILURE" end)

    assert {:done, ^id} = Restore.settle(ctx.scope, ctx.box, id, trusted_options())
    assert read(ctx).restores == [["message-1"]]
    assert [%Effect{state: :done, applied_at: %DateTime{}}] = effects(ctx)
  end

  for promoted_before_restore <- [true, false] do
    test "actual digest withdrawal survives callback failure with early promotion #{promoted_before_restore}",
         ctx do
      promoted_before_restore = unquote(promoted_before_restore)
      alias EmailJanitor.Digest
      alias EmailJanitor.Digest.{Activity, Event}

      :ok = EmailJanitor.Mail.Store.install(ctx.scope)
      :ok = Digest.install(ctx.scope)
      :ok = Digest.install_staging(ctx.scope)
      now = DateTime.utc_now()
      :ok = Digest.configure(ctx.scope, ctx.box.id, "Etc/UTC", now)

      for {id, subject} <- [
            {"message-1", "Restored synthetic subject"},
            {"message-2", "Retained synthetic subject"}
          ] do
        {:ok, event} = Event.new(ctx.action_id, id, :done, "sender@example.com", subject, now)
        :ok = Digest.stage(ctx.scope, ctx.box.id, event)
      end

      if promoted_before_restore, do: Digest.confirm_staged(ctx.scope, ctx.box.id, ctx.action_id)

      assert {:unresolved, effect_id} =
               restore(ctx,
                 on_restored: fn action, ids ->
                   assert action == ctx.action_id
                   :ok = Digest.withdraw_pending(ctx.scope, ctx.box.id, ids)
                   {:error, :synthetic_callback_failure}
                 end
               )

      assert {:done, ^effect_id} = Restore.outcome(ctx.scope, ctx.box, effect_id)

      if promoted_before_restore do
        # Callback rollback cannot remove already committed positive source proof.
        refute Repo.get_by!(Activity, [message_id: "message-1"], prefix: ctx.scope.prefix).retired
      else
        # A distinct connection can promote late after the restore's owner exits.
        assert :ok =
                 Task.async(fn -> Digest.confirm_staged(ctx.scope, ctx.box.id, ctx.action_id) end)
                 |> Task.await()

        assert Repo.get_by!(Activity, [message_id: "message-1"], prefix: ctx.scope.prefix).retired
      end

      assert {:ok, {:ready, snapshot}} =
               Digest.tick(ctx.scope, ctx.box.id, DateTime.add(now, 86_400))

      assert {:ok, rendered} = Digest.render(ctx.scope, snapshot.id)
      refute Content.read(rendered.text) =~ "Restored synthetic subject"
      assert Content.read(rendered.text) =~ "Retained synthetic subject"

      assert {:done, ^effect_id} =
               Restore.settle(
                 ctx.scope,
                 ctx.box,
                 effect_id,
                 Keyword.put(trusted_options(), :on_restored, fn _, ids ->
                   Digest.withdraw_pending(ctx.scope, ctx.box.id, ids)
                 end)
               )

      assert read(ctx).restores == [["message-1"]]
      assert Store.get(ctx.scope, ctx.box.id, ctx.action_id).state == :done
    end
  end

  test "restoration between safeguard read and admission fences a newly arrived sibling", ctx do
    Agent.update(ctx.state, &%{&1 | messages: &1.messages ++ [Fixtures.message(id: "message-3")]})
    gmail = {EmailJanitor.TestGmail, [state: ctx.state]}

    assert {:ok, proposal} =
             Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               gmail,
               {EmailJanitor.TestClassifier, []},
               "Synthetic instructions",
               1
             )

    assert proposal.message_ids == ["message-3"]
    parent = self()

    history_hook = fn ->
      task = Task.async(fn -> restore(ctx) end)
      assert {:done, _} = Task.await(task, 5_000)
      send(parent, :restored_after_safeguards)
    end

    result =
      Executor.execute(
        ctx.scope,
        ctx.box,
        proposal,
        {EmailJanitor.TestGmail, [state: ctx.state, history_hook: history_hook]}
      )

    assert result in [{:error, :proposal_changed}, {:skip, :proposal_changed}]
    assert_received :restored_after_safeguards
    assert length(Repo.all(EmailJanitor.Store.Action, prefix: ctx.scope.prefix)) == 1
    assert "INBOX" in Enum.find(read(ctx).messages, &(&1.id == "message-3")).labels
    assert read(ctx).calls == [["message-1", "message-2"]]
  end

  test "a concurrent restoration after intent defeats the final dispatch fence", ctx do
    Agent.update(ctx.state, &%{&1 | messages: &1.messages ++ [Fixtures.message(id: "message-3")]})
    gmail = {EmailJanitor.TestGmail, [state: ctx.state]}

    assert {:ok, proposal} =
             Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               gmail,
               {EmailJanitor.TestClassifier, []},
               "Synthetic instructions",
               1
             )

    parent = self()

    task =
      Task.async(fn ->
        EmailJanitor.Owner.run(fn ->
          assert {:ok, {:created, action}} =
                   Store.intent(ctx.scope, ctx.box.id, proposal, "100",
                     observed_message_ids: ["message-1", "message-2", "message-3"]
                   )

          send(parent, {:intent, self(), action.id})

          receive do
            :dispatch -> :ok
          after
            5_000 -> flunk("dispatch not released")
          end

          assert {:error, :proposal_changed} =
                   Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)

          assert :ok = Store.cancel_prepared(ctx.scope, ctx.box.id, action.id, action.owner_token)
          :ok
        end)
      end)

    assert_receive {:intent, owner, action_id}, 2_000

    assert Store.get(ctx.scope, ctx.box.id, action_id).observed_message_ids == [
             "message-1",
             "message-2",
             "message-3"
           ]

    assert {:done, _} = restore(ctx)
    send(owner, :dispatch)
    assert :ok = Task.await(task, 5_000)
    assert Store.get(ctx.scope, ctx.box.id, action_id).dispatch_started_at == nil
    assert "INBOX" in Enum.find(read(ctx).messages, &(&1.id == "message-3")).labels
  end

  test "unobserved pre-M7 prepared intents cannot dispatch even without restoration", ctx do
    Agent.update(ctx.state, &%{&1 | messages: &1.messages ++ [Fixtures.message(id: "message-3")]})

    assert {:ok, proposal} =
             Executor.review(
               ctx.scope,
               ctx.box,
               "thread-1",
               {EmailJanitor.TestGmail, [state: ctx.state]},
               {EmailJanitor.TestClassifier, []},
               "Synthetic instructions",
               1
             )

    assert :ok =
             EmailJanitor.Owner.run(fn ->
               assert {:ok, {:created, action}} =
                        Store.intent(ctx.scope, ctx.box.id, proposal, "100")

               Repo.update!(Ecto.Changeset.change(action, observed_message_ids: nil),
                 prefix: ctx.scope.prefix
               )

               assert {:error, :proposal_changed} =
                        Store.begin_dispatch(ctx.scope, ctx.box.id, action.id, action.owner_token)

               :ok
             end)

    assert "INBOX" in Enum.find(read(ctx).messages, &(&1.id == "message-3")).labels
  end

  test "settlement retires only older exact candidate metadata and preserves newer reviews",
       ctx do
    old = seed_candidate(ctx, ["message-1", "message-3"], -60)
    policy = %EmailJanitor.Policy{adapter: __MODULE__.Policy, context: self()}

    assert {:unresolved, effect_id} =
             restore(ctx,
               policy: policy,
               on_restored: fn _, _ -> {:error, :retry_later} end
             )

    # Reporting failure rolls back metadata retirement but not the positive wire proof.
    assert Repo.get!(EmailJanitor.Store.Candidate, old.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["message-1", "message-3"]

    assert_received {:retired, :exact, old_id, ["message-1"]}
    assert old_id == old.id
    newer = seed_candidate(ctx, ["message-1", "message-4"], 0)
    [effect] = effects(ctx)
    assert DateTime.compare(newer.updated_at, effect.applied_at) == :gt

    assert {:done, ^effect_id} =
             Restore.settle(
               ctx.scope,
               ctx.box,
               effect_id,
               Keyword.put(trusted_options(), :policy, policy)
             )

    assert_received {:retired, :exact, ^old_id, ["message-1"]}
    newer_id = newer.id
    refute_received {:retired, _, ^newer_id, _}

    assert Repo.get!(EmailJanitor.Store.Candidate, old.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["message-3"]

    assert Repo.get!(EmailJanitor.Store.Candidate, newer.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["message-1", "message-4"]

    assert read(ctx).restores == [["message-1"]]
  end

  test "a trusted requeue after applied_at survives a delayed old restoration settlement", ctx do
    :ok = EmailJanitor.Worker.install(ctx.scope)
    candidate = seed_candidate(ctx, ["message-1", "message-3"], -60)

    Repo.insert!(
      %EmailJanitor.Worker.Candidate{
        inbox_id: ctx.box.id,
        candidate_id: candidate.id,
        generation: Ecto.UUID.generate(),
        thread_id: "thread-1",
        message_ids: candidate.message_ids,
        inserted_at: candidate.inserted_at,
        updated_at: candidate.updated_at
      },
      prefix: ctx.scope.prefix
    )

    assert {:unresolved, effect_id} =
             restore(ctx, on_restored: fn _, _ -> {:error, :retry_later} end)

    assert :ok = EmailJanitor.Worker.queue_recheck(ctx.scope, ctx.box, candidate.id)
    assert {:done, ^effect_id} = Restore.settle(ctx.scope, ctx.box, effect_id, trusted_options())

    assert Repo.get!(EmailJanitor.Store.Candidate, candidate.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["message-1", "message-3"]

    assert [%EmailJanitor.Worker.Candidate{requested: true, request_version: 2}] =
             Repo.all(EmailJanitor.Worker.Candidate, prefix: ctx.scope.prefix)

    assert read(ctx).restores == [["message-1"]]
  end

  for {selection, refresh} <- [
        {:new, true},
        {:same, true},
        {:new, false},
        {:same, false},
        {:changed, false},
        {:changed, true}
      ] do
    test "manual queue #{selection} refresh=#{refresh} distinguishes new authority from ordinary discovery",
         ctx do
      check_manual_queue_after_restore(ctx, unquote(selection), unquote(refresh))
    end
  end

  defp check_manual_queue_after_restore(ctx, selection, refresh) do
    alias EmailJanitor.Worker
    :ok = Worker.install(ctx.scope)

    {:ok, _} =
      EmailJanitor.Gmail.Ingestion.baseline(ctx.scope, ctx.box, %{
        history_id: "100",
        expires_at: DateTime.add(DateTime.utc_now(), 604_800)
      })

    candidate = seed_candidate(ctx, ["message-1", "message-3"], -60)

    if selection != :new do
      ids = if selection == :changed, do: candidate.message_ids, else: ["message-1"]

      :ok =
        Worker.queue_manual(ctx.scope, ctx.box, candidate.id, "thread-1", ids,
          authority_id: candidate.id
        )
    end

    policy = %EmailJanitor.Policy{
      adapter: __MODULE__.Policy,
      context: %{owner: self(), scope: ctx.scope, inbox: ctx.box}
    }

    assert {:unresolved, effect_id} =
             restore(ctx, policy: policy, on_restored: fn _, _ -> {:error, :retry} end)

    before = Repo.get_by(Worker.Candidate, [candidate_id: candidate.id], prefix: ctx.scope.prefix)

    :ok =
      Worker.queue_manual(ctx.scope, ctx.box, candidate.id, "thread-1", ["message-1"],
        authority_id: candidate.id,
        refresh_authority: refresh
      )

    if before && refresh do
      :ok =
        Worker.Ledger.finish_candidate(
          ctx.scope,
          ctx.box,
          before,
          :unsupported_policy,
          DateTime.utc_now()
        )
    end

    assert {:done, ^effect_id} =
             Restore.settle(
               ctx.scope,
               ctx.box,
               effect_id,
               Keyword.put(trusted_options(), :policy, policy)
             )

    core = Repo.get!(EmailJanitor.Store.Candidate, candidate.id, prefix: ctx.scope.prefix)
    row = Repo.get_by!(Worker.Candidate, [candidate_id: candidate.id], prefix: ctx.scope.prefix)

    if refresh do
      assert core.remaining_message_ids == ["message-1", "message-3"]
      assert row.message_ids == ["message-1"] and row.requested and not row.contract_blocked
    else
      assert core.remaining_message_ids == ["message-3"]
      assert row.status == :retired and row.message_ids == [] and not row.requested
    end

    assert read(ctx).restores == [["message-1"]]
  end

  test "host exact retirement keeps unrelated arrival provenance available for recheck", ctx do
    :ok = EmailJanitor.Worker.install(ctx.scope)
    candidate = seed_candidate(ctx, ["message-1", "message-3"], -60)

    Repo.insert!(
      %EmailJanitor.Worker.Candidate{
        inbox_id: ctx.box.id,
        candidate_id: candidate.id,
        generation: Ecto.UUID.generate(),
        thread_id: "thread-1",
        message_ids: candidate.message_ids,
        requested: true,
        inserted_at: candidate.inserted_at,
        updated_at: candidate.updated_at
      },
      prefix: ctx.scope.prefix
    )

    policy = %EmailJanitor.Policy{
      adapter: __MODULE__.Policy,
      context: %{owner: self(), scope: ctx.scope, inbox: ctx.box}
    }

    parent = self()

    stale_finisher =
      Task.async(fn ->
        snapshot =
          Repo.get_by!(EmailJanitor.Worker.Candidate, [candidate_id: candidate.id],
            prefix: ctx.scope.prefix
          )

        send(parent, :candidate_snapshot_read)

        receive do
          :finish ->
            EmailJanitor.Worker.Ledger.finish_candidate(
              ctx.scope,
              ctx.box,
              snapshot,
              :unsupported_policy,
              DateTime.utc_now()
            )
        end
      end)

    assert_receive :candidate_snapshot_read
    assert {:done, _} = restore(ctx, policy: policy)
    send(stale_finisher.pid, :finish)
    assert :ok = Task.await(stale_finisher)

    assert [
             %EmailJanitor.Worker.Candidate{
               message_ids: ["message-3"],
               status: :pending,
               requested: true,
               contract_blocked: false,
               request_version: 2
             }
           ] =
             Repo.all(EmailJanitor.Worker.Candidate, prefix: ctx.scope.prefix)

    :ok =
      EmailJanitor.Worker.Ledger.retire_candidate(ctx.scope, ctx.box, candidate.id, ["message-1"])

    assert [%EmailJanitor.Worker.Candidate{request_version: 2}] =
             Repo.all(EmailJanitor.Worker.Candidate, prefix: ctx.scope.prefix)

    assert :ok = EmailJanitor.Worker.queue_recheck(ctx.scope, ctx.box, candidate.id)

    assert [%EmailJanitor.Worker.Candidate{message_ids: ["message-3"], requested: true}] =
             Repo.all(EmailJanitor.Worker.Candidate, prefix: ctx.scope.prefix)
  end

  test "retirement serializes its version with a concurrent bulk backlog request", ctx do
    :ok = EmailJanitor.Worker.install(ctx.scope)
    candidate = seed_candidate(ctx, ["message-1", "message-3"], -60)

    Repo.insert!(
      %EmailJanitor.Worker.Candidate{
        inbox_id: ctx.box.id,
        candidate_id: candidate.id,
        generation: Ecto.UUID.generate(),
        thread_id: "thread-1",
        message_ids: candidate.message_ids,
        inserted_at: candidate.inserted_at,
        updated_at: candidate.updated_at
      },
      prefix: ctx.scope.prefix
    )

    parent = self()

    backlog =
      Task.async(fn ->
        Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(
            Repo,
            ~s|SELECT candidate_id FROM "#{ctx.scope.prefix}".janitor_worker_candidates WHERE candidate_id = $1 FOR UPDATE|,
            [Ecto.UUID.dump!(candidate.id)],
            log: false
          )

          assert {:ok, 1} = EmailJanitor.Worker.queue_backlog(ctx.scope, ctx.box)
          send(parent, :bulk_request_uncommitted)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :bulk_request_uncommitted, 2_000

    retirement =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} =
            Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [], log: false)

          send(parent, {:retirement_backend, backend})

          EmailJanitor.Worker.Ledger.retire_candidate(ctx.scope, ctx.box, candidate.id, [
            "message-1"
          ])
        end)
      end)

    assert_receive {:retirement_backend, backend}, 2_000
    await_blocked(backend, 200)
    send(backlog.pid, :commit)
    assert {:ok, :ok} = Task.await(backlog)
    assert :ok = Task.await(retirement)

    assert [
             %EmailJanitor.Worker.Candidate{
               message_ids: ["message-3"],
               request_version: 3,
               requested: true
             }
           ] =
             Repo.all(EmailJanitor.Worker.Candidate, prefix: ctx.scope.prefix)
  end

  defp seed_candidate(ctx, ids, seconds) do
    %{rows: [[now]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT clock_timestamp()", [], log: false)
    at = DateTime.add(now, seconds)
    ids = Enum.sort(ids)

    Repo.insert!(
      %EmailJanitor.Store.Candidate{
        inbox_id: ctx.box.id,
        thread_id: "thread-1",
        message_ids: ids,
        remaining_message_ids: ids,
        evaluated_message_ids: ids,
        message_key: :crypto.hash(:sha256, :erlang.term_to_binary(ids)),
        inserted_at: at,
        updated_at: at
      },
      prefix: ctx.scope.prefix
    )
  end

  test "errors and ordinary inspection expose no transient contents or raw provider failures",
       ctx do
    import ExUnit.CaptureLog

    gmail =
      {__MODULE__.Gmail, [state: ctx.state, on_prepare: fn -> raise "PRIVATE_SECRET_BODY" end]}

    logs =
      capture_log(fn -> assert {:error, :gmail_unavailable} = restore(%{ctx | gmail: gmail}) end)

    refute logs =~ "PRIVATE_SECRET_BODY"
    assert effects(ctx) == []
    assert {:done, _} = restore(ctx)
    refute inspect(effects(ctx)) =~ "owner_beam_pid"
    assert Enum.all?(read(ctx).messages, &match?(%Content{}, &1.body))
  end
end

defmodule EmailJanitor.RestoreTest.Policy do
  @behaviour EmailJanitor.Policy
  def reserve(_, _, _, _, _), do: :ok
  def settle(_, _, _, _), do: :ok
  def retire_candidate(owner, _, id, ids), do: retire(owner, :whole, id, ids)
  def retire_candidate_messages(owner, _, id, ids), do: retire(owner, :exact, id, ids)

  defp retire(%{owner: owner, scope: scope, inbox: inbox}, mode, id, ids) do
    send(owner, {:retired, mode, id, ids})
    EmailJanitor.Worker.Ledger.retire_candidate(scope, inbox, id, ids)
  end

  defp retire(owner, mode, id, ids) do
    send(owner, {:retired, mode, id, ids})
    :ok
  end
end

defmodule EmailJanitor.RestoreTest.Repo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.RestoreTest.Gmail do
  def prepare_add_inbox(_, ids, opts) do
    if callback = opts[:on_prepare], do: callback.()

    {:ok,
     fn ->
       if callback = opts[:before_wire], do: callback.()

       result =
         Agent.get_and_update(opts[:state], fn state ->
           rejected? = match?({:rejected, _}, state.mode)

           messages =
             Enum.map(state.messages, fn message ->
               if message.id in ids and not rejected?,
                 do: %{message | labels: Enum.uniq(["INBOX" | message.labels])},
                 else: message
             end)

           result =
             case state.mode do
               :timeout -> {:error, :timeout}
               {:rejected, _} = rejected -> rejected
               _ -> :ok
             end

           {result, %{state | messages: messages, restores: state.restores ++ [ids]}}
         end)

       if callback = opts[:after_wire], do: callback.()
       result
     end}
  end
end
