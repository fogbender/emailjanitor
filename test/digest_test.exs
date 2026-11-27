defmodule EmailJanitor.DigestTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias EmailJanitor.{Content, Digest, Store, TestRepo}
  alias EmailJanitor.Digest.{Activity, Event, Schedule, Snapshot, Worker}
  alias EmailJanitor.Mail.{Outbox, Outgoing}
  alias EmailJanitor.MailFixture, as: F
  alias EmailJanitor.Store.Scope

  @start ~U[2026-11-20 12:00:00Z]
  @due ~U[2026-11-20 21:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    {:ok, scope} = Scope.new(TestRepo, "ej_test_a")
    {:ok, other} = Scope.new(TestRepo, "ej_test_b")
    inbox = F.inbox()

    for target <- [scope, other] do
      {:ok, _} = Store.add_inbox(target, inbox)
      :ok = Digest.configure(target, inbox.id, "Etc/UTC", @start)

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "CREATE TABLE #{target.prefix}.digest_host_claims (message_id text PRIMARY KEY, digest_id text NOT NULL)",
        [],
        log: false
      )
    end

    %{scope: scope, other: other, inbox: inbox}
  end

  defp event(scope, inbox, number, kind \\ :done, at \\ ~U[2026-11-20 20:00:00Z]) do
    {:ok, event} =
      Event.new(
        Ecto.UUID.generate(),
        Integer.to_string(number, 16) |> String.downcase(),
        kind,
        "Sender <sender@example.com>",
        "Subject #{number}",
        at
      )

    {:ok, row} = Digest.record(scope, inbox.id, event)
    row
  end

  defp claims(scope, observer \\ nil) do
    fn _inbox, digest_id, cutoff, ids ->
      assert TestRepo.in_transaction?()
      if observer, do: send(observer, {:claim, ids, digest_id, cutoff})

      {_, rows} =
        TestRepo.insert_all(
          "digest_host_claims",
          Enum.map(ids, &%{message_id: &1, digest_id: digest_id}),
          on_conflict: :nothing,
          conflict_target: [:message_id],
          returning: [:message_id],
          prefix: scope.prefix
        )

      {:ok, Enum.map(rows, & &1.message_id)}
    end
  end

  defp send_digest(ctx, snapshot, now \\ @due, plug \\ &F.ses_response/1) do
    Digest.deliver(ctx.scope, snapshot.id, F.config(plug), fn _ -> {:ok, ctx.inbox} end,
      clock: fn -> now end
    )
  end

  test "new schedule does not immediately catch up yesterday, and inactive days send nothing",
       ctx do
    assert {:ok, :not_due} = Digest.tick(ctx.scope, ctx.inbox.id, @start)
    assert {:ok, :not_due} = Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-20 20:59:59.999999Z])
    assert {:ok, :inactive} = Digest.tick(ctx.scope, ctx.inbox.id, @due)
    assert TestRepo.aggregate(Outgoing, :count, prefix: ctx.scope.prefix) == 0
    assert {:ok, :not_due} = Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-20 21:05:00Z])
  end

  test "confirmed settlement records before a valid browser schedule exists", ctx do
    TestRepo.delete_all(Schedule, prefix: ctx.scope.prefix)

    assert {:error, :invalid_digest_schedule} =
             Digest.configure(ctx.scope, ctx.inbox.id, "Unknown/Browser", @start)

    assert {:ok, activity} =
             TestRepo.transaction(fn ->
               row = event(ctx.scope, ctx.inbox, 71)

               TestRepo.insert_all(
                 "digest_host_claims",
                 [%{message_id: "settled", digest_id: row.id}],
                 prefix: ctx.scope.prefix
               )

               row
             end)

    assert TestRepo.get!(Activity, activity.id, prefix: ctx.scope.prefix).digest_id == nil
    assert TestRepo.aggregate("digest_host_claims", :count, prefix: ctx.scope.prefix) == 1
    assert :ok = Digest.configure(ctx.scope, ctx.inbox.id, "Etc/UTC", @start)
    assert {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, @due)
    assert {:ok, message} = Digest.render(ctx.scope, snapshot.id)
    assert Content.read(message.text) =~ "Subject 71"
  end

  test "delayed tick excludes late activity, first digest teaches replies, and snapshots stay frozen",
       ctx do
    first = event(ctx.scope, ctx.inbox, 1)
    event(ctx.scope, ctx.inbox, 2, :done, ~U[2026-11-20 21:01:00Z])

    assert {:ok, {:ready, snapshot}} =
             Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-20 21:05:00Z])

    assert {:ok, message} = Digest.render(ctx.scope, snapshot.id)
    body = Content.read(message.text)
    assert body =~ "Reply to this email"
    assert body =~ "sender@example.com\nSubject 1"
    refute body =~ "Subject 2"
    event(ctx.scope, ctx.inbox, 3, :done, ~U[2026-11-20 20:30:00Z])
    assert {:ok, message2} = Digest.render(ctx.scope, snapshot.id)
    assert Content.read(message2.text) == body
    assert TestRepo.get!(Activity, first.id, prefix: ctx.scope.prefix).digest_id == snapshot.id
    assert :ok = send_digest(ctx, snapshot)
    assert {:ok, {:ready, next}} = Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-21 21:00:00Z])
    assert {:ok, next_message} = Digest.render(ctx.scope, next.id)
    refute Content.read(next_message.text) =~ "Reply to this email"
    assert Content.read(next_message.text) =~ "Subject 2"
    assert Content.read(next_message.text) =~ "Subject 3"
    refute Content.read(next_message.text) =~ "Subject 1"
  end

  test "hypotheticals are claimed atomically once; late IDs stay untouched", ctx do
    event(ctx.scope, ctx.inbox, 10, :would_have_done)
    event(ctx.scope, ctx.inbox, 11, :would_have_done, ~U[2026-11-20 21:02:00Z])

    assert {:ok, {:ready, snapshot}} =
             Digest.tick(
               ctx.scope,
               ctx.inbox.id,
               ~U[2026-11-20 21:05:00Z],
               claims(ctx.scope, self())
             )

    assert_received {:claim, ["a"], id, cutoff}
    assert DateTime.compare(cutoff, @due) == :eq
    assert id == snapshot.id
    assert {:ok, message} = Digest.render(ctx.scope, snapshot.id, "Upgrade in your account.")
    assert Content.read(message.text) =~ "Would have been marked Done"
    assert Content.read(message.text) =~ "Subject 10"
    refute Content.read(message.text) =~ "Subject 11"
    assert :ok = send_digest(ctx, snapshot)

    assert {:ok, {:ready, next}} =
             Digest.tick(
               ctx.scope,
               ctx.inbox.id,
               ~U[2026-11-21 21:00:00Z],
               claims(ctx.scope, self())
             )

    assert_received {:claim, ["b"], _, next_cutoff}
    assert DateTime.compare(next_cutoff, ~U[2026-11-21 21:00:00Z]) == :eq
    assert {:ok, next_message} = Digest.render(ctx.scope, next.id)
    refute Content.read(next_message.text) =~ "Subject 10"
  end

  test "invalid host claim rolls back listing, schedule, snapshot and outbox", ctx do
    row = event(ctx.scope, ctx.inbox, 12, :would_have_done)

    callback = fn inbox, digest, cutoff, ids ->
      claims(ctx.scope).(inbox, digest, cutoff, ids)
      {:ok, ["not-in-the-frozen-set"]}
    end

    assert {:error, :invalid_digest_claim} = Digest.tick(ctx.scope, ctx.inbox.id, @due, callback)
    assert TestRepo.aggregate("digest_host_claims", :count, prefix: ctx.scope.prefix) == 0
    assert TestRepo.aggregate(Snapshot, :count, prefix: ctx.scope.prefix) == 0
    assert TestRepo.aggregate(Outgoing, :count, prefix: ctx.scope.prefix) == 0
    assert TestRepo.get!(Activity, row.id, prefix: ctx.scope.prefix).digest_id == nil

    assert DateTime.compare(
             TestRepo.get!(Schedule, ctx.inbox.id, prefix: ctx.scope.prefix).last_cutoff,
             ~U[2026-11-19 21:00:00Z]
           ) == :eq

    assert {:ok, {:ready, _}} = Digest.tick(ctx.scope, ctx.inbox.id, @due, claims(ctx.scope))
  end

  test "successful cleanup retires unlisted hypothetical and a manual restore can retire another",
       ctx do
    old = event(ctx.scope, ctx.inbox, 15, :would_have_done)
    event(ctx.scope, ctx.inbox, 15, :done)
    other = event(ctx.scope, ctx.inbox, 16, :would_have_done)
    :ok = Digest.retire_hypotheticals(ctx.scope, ctx.inbox.id, [other.message_id])
    assert TestRepo.get!(Activity, old.id, prefix: ctx.scope.prefix).retired

    assert {:ok, {:ready, snapshot}} =
             Digest.tick(ctx.scope, ctx.inbox.id, @due, fn _, _, _, _ ->
               flunk("retired extra claimed")
             end)

    assert {:ok, message} = Digest.render(ctx.scope, snapshot.id)
    assert Content.read(message.text) =~ "Marked Done"
    refute Content.read(message.text) =~ "Would have been marked Done"
    refute Content.read(message.text) =~ "Subject 16"
  end

  test "pending frozen digest recovers once after downtime and defers new activity without dropping it",
       ctx do
    event(ctx.scope, ctx.inbox, 20)
    {:ok, {:ready, old}} = Digest.tick(ctx.scope, ctx.inbox.id, @due)
    event(ctx.scope, ctx.inbox, 21, :done, ~U[2026-11-22 20:00:00Z])
    recovery = ~U[2026-11-23 22:00:00Z]
    assert {:ok, {:ready, recovered}} = Digest.tick(ctx.scope, ctx.inbox.id, recovery)
    assert recovered.id == old.id
    assert :ok = send_digest(ctx, recovered, recovery)
    assert {:ok, :not_due} = Digest.tick(ctx.scope, ctx.inbox.id, recovery)
    assert {:ok, {:ready, next}} = Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-24 21:00:00Z])
    assert {:ok, message} = Digest.render(ctx.scope, next.id)
    assert Content.read(message.text) =~ "Subject 21"
    refute Content.read(message.text) =~ "Subject 20"
  end

  test "different inbox scopes never share activity, schedules or delivery slots", ctx do
    event(ctx.scope, ctx.inbox, 30)
    event(ctx.other, ctx.inbox, 31)
    {:ok, {:ready, a}} = Digest.tick(ctx.scope, ctx.inbox.id, @due)
    {:ok, {:ready, b}} = Digest.tick(ctx.other, ctx.inbox.id, @due)
    assert Digest.get(ctx.other, a.id) == nil
    {:ok, ma} = Digest.render(ctx.scope, a.id)
    {:ok, mb} = Digest.render(ctx.other, b.id)
    refute Content.read(ma.text) =~ "Subject 31"
    refute Content.read(mb.text) =~ "Subject 30"
    assert :ok = send_digest(ctx, a)
    assert TestRepo.get!(Schedule, ctx.inbox.id, prefix: ctx.other.prefix).delivery_date == nil
  end

  test "fresh admission clock after credentials preparation controls the dispatch day", ctx do
    event(ctx.scope, ctx.inbox, 40)
    {:ok, {:ready, old}} = Digest.tick(ctx.scope, ctx.inbox.id, @due)
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-11-21 23:59:59Z] end)
    config = F.config(&F.ses_response/1)
    credential_resolver = config.credentials

    config = %{
      config
      | credentials: fn ->
          Agent.update(clock, fn _ -> ~U[2026-11-22 00:00:01Z] end)
          credential_resolver.()
        end
    }

    assert :ok =
             Digest.deliver(ctx.scope, old.id, config, fn _ -> {:ok, ctx.inbox} end,
               clock: fn -> Agent.get(clock, & &1) end
             )

    schedule = TestRepo.get!(Schedule, ctx.inbox.id, prefix: ctx.scope.prefix)
    assert schedule.delivery_date == ~D[2026-11-22]
    assert schedule.delivery_digest_id == old.id

    assert {:ok, :daily_slot_used} =
             Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-22 21:00:00Z])
  end

  test "admission is atomic with send fence and never includes provider I/O in a transaction",
       ctx do
    event(ctx.scope, ctx.inbox, 50)
    {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, @due)
    parent = self()

    config =
      F.config(fn conn ->
        send(parent, {:provider_transaction, TestRepo.in_transaction?()})
        F.ses_response(conn)
      end)

    assert :ok = send_digest(ctx, snapshot, @due, config.test_plug)
    assert_received {:provider_transaction, false}
    assert Outbox.get(ctx.scope, snapshot.outbox_id).state == :sent

    assert TestRepo.get!(Schedule, ctx.inbox.id, prefix: ctx.scope.prefix).delivery_digest_id ==
             snapshot.id
  end

  test "a failed connection affects only that inbox and the supervised worker resumes after restart",
       ctx do
    event(ctx.scope, ctx.inbox, 60)
    event(ctx.other, ctx.inbox, 61)
    parent = self()

    opts = [
      inboxes: fn -> [{ctx.scope, ctx.inbox.id}, {ctx.other, ctx.inbox.id}] end,
      mail:
        F.config(fn conn ->
          send(parent, :sent)
          F.ses_response(conn)
        end),
      clock: fn -> @due end,
      authorize: fn scope, _ ->
        if scope == ctx.scope, do: {:error, :disconnected}, else: {:ok, ctx.inbox}
      end
    ]

    opts = Keyword.put(opts, :jobs, EmailJanitor.TestScheduler.jobs())
    tasks = Worker.tasks(opts)
    EmailJanitor.TestScheduler.start_tasks(tasks, queues: [discovery: 1, digest: 1])
    assert_receive :sent, 5_000

    EmailJanitor.TestScheduler.await(fn ->
      TestRepo.one(from(o in Outgoing, select: o.state), prefix: ctx.other.prefix) == :sent
    end)

    EmailJanitor.TestScheduler.await(fn ->
      rows = EmailJanitor.TestScheduler.rows("digest")
      length(rows) == 2 and Enum.all?(rows, &(&1.state == "scheduled"))
    end)

    before = EmailJanitor.TestScheduler.rows("digest")
    assert :ok = stop_supervised({EmailJanitor.Jobs, EmailJanitor.TestScheduler.jobs()})

    assert Outbox.get(ctx.scope, Digest.pending(ctx.scope, ctx.inbox.id).outbox_id).state ==
             :pending

    EmailJanitor.TestScheduler.start_tasks(tasks, queues: [discovery: 1, digest: 1])
    after_restart = EmailJanitor.TestScheduler.rows("digest")

    assert Enum.map(after_restart, &{&1.id, &1.args, &1.scheduled_at}) ==
             Enum.map(before, &{&1.id, &1.args, &1.scheduled_at})

    assert {:ok, %{failed: 1, idle: 1}} = Worker.run_once(opts)
    refute_received :sent
  end

  test "metadata overflow remains unlisted and host claims are chunked without a daily plan limit",
       ctx do
    sender = "s@a.co"
    subject = "S"

    {:ok, prototype} =
      Event.new(
        Ecto.UUID.generate(),
        "1",
        :would_have_done,
        sender,
        subject,
        ~U[2026-11-20 20:00:00Z]
      )

    now = DateTime.utc_now()

    rows =
      for n <- 1..6200 do
        %{
          id: Ecto.UUID.generate(),
          inbox_id: ctx.inbox.id,
          source_id: Ecto.UUID.generate(),
          message_id: Integer.to_string(n, 16) |> String.downcase(),
          kind: :would_have_done,
          sender: prototype.sender,
          subject: prototype.subject,
          occurred_at: prototype.occurred_at,
          inserted_at: now,
          updated_at: now
        }
      end

    Enum.each(
      Enum.chunk_every(rows, 500),
      &TestRepo.insert_all(Activity, &1, prefix: ctx.scope.prefix)
    )

    parent = self()

    claim = fn _, _, _, ids ->
      send(parent, {:batch_size, length(ids)})
      {:ok, ids}
    end

    assert {:ok, {:ready, first}} = Digest.tick(ctx.scope, ctx.inbox.id, @due, claim)

    count = fn snapshot ->
      TestRepo.aggregate(from(a in Activity, where: a.digest_id == ^snapshot.id), :count,
        prefix: ctx.scope.prefix
      )
    end

    selected = count.(first)
    assert selected > 1000 and selected < 6200
    {:ok, message} = Digest.render(ctx.scope, first.id)

    assert byte_size(Content.read(message.text)) <=
             EmailJanitor.Digest.Renderer.max_digest_bytes()

    assert Enum.count(String.split(Content.read(message.text), "\n"), &(&1 == subject)) ==
             selected

    assert_receive {:batch_size, 500}
    assert :ok = send_digest(ctx, first)

    assert {:ok, {:ready, second}} =
             Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-21 21:00:00Z], claim)

    assert :ok = send_digest(ctx, second, ~U[2026-11-21 21:00:00Z])

    assert {:ok, {:ready, third}} =
             Digest.tick(ctx.scope, ctx.inbox.id, ~U[2026-11-22 21:00:00Z], claim)

    assert selected + count.(second) + count.(third) == 6200

    assert TestRepo.aggregate(from(a in Activity, where: is_nil(a.digest_id)), :count,
             prefix: ctx.scope.prefix
           ) == 0
  end

  test "rejected admission rolls back host state and never crosses the send fence", ctx do
    event(ctx.scope, ctx.inbox, 70)
    {:ok, {:ready, snapshot}} = Digest.tick(ctx.scope, ctx.inbox.id, @due)

    admission = fn _ ->
      assert TestRepo.in_transaction?()

      TestRepo.update_all(
        from(s in Schedule, where: s.inbox_id == ^ctx.inbox.id),
        [set: [delivery_date: ~D[2026-11-20]]],
        prefix: ctx.scope.prefix
      )

      {:error, :host_policy_rejected}
    end

    assert {:error, :mail_admission_rejected} =
             Outbox.deliver(
               ctx.scope,
               snapshot.outbox_id,
               F.config(fn _ -> flunk("provider called after rejected admission") end),
               fn _ -> {:ok, ctx.inbox} end,
               fn _ -> Digest.render(ctx.scope, snapshot.id) end,
               admission
             )

    assert Outbox.get(ctx.scope, snapshot.outbox_id).state == :pending
    assert TestRepo.get!(Schedule, ctx.inbox.id, prefix: ctx.scope.prefix).delivery_date == nil
  end

  test "hypothetical retries with a new review source retain one immutable metadata entry", ctx do
    first = event(ctx.scope, ctx.inbox, 75, :would_have_done)
    repeated = event(ctx.scope, ctx.inbox, 75, :would_have_done)
    assert repeated.id == first.id

    assert {:ok, {:ready, snapshot}} =
             Digest.tick(ctx.scope, ctx.inbox.id, @due, claims(ctx.scope))

    assert TestRepo.aggregate(from(a in Activity, where: a.digest_id == ^snapshot.id), :count,
             prefix: ctx.scope.prefix
           ) == 1
  end

  test "persisted schedule and delivery dates follow local DST across spring-forward", ctx do
    {:ok, box} = EmailJanitor.Inbox.new("la-inbox", "la-owner@example.com")
    {:ok, _} = Store.add_inbox(ctx.scope, box)

    assert :ok =
             Digest.configure(ctx.scope, box.id, "America/Los_Angeles", ~U[2026-03-07 12:00:00Z])

    event(ctx.scope, box, 80, :done, ~U[2026-03-08 04:55:00Z])
    assert {:ok, :not_due} = Digest.tick(ctx.scope, box.id, ~U[2026-03-08 04:59:59Z])
    assert {:ok, {:ready, first}} = Digest.tick(ctx.scope, box.id, ~U[2026-03-08 05:00:00Z])
    assert first.local_date == ~D[2026-03-07]
    assert :ok = send_digest(%{ctx | inbox: box}, first, ~U[2026-03-08 05:00:00Z])
    event(ctx.scope, box, 81, :done, ~U[2026-03-09 03:55:00Z])
    assert {:ok, {:ready, next}} = Digest.tick(ctx.scope, box.id, ~U[2026-03-09 04:00:00Z])
    assert next.local_date == ~D[2026-03-08]
    assert DateTime.diff(next.cutoff, first.cutoff) == 23 * 3600
    assert :ok = send_digest(%{ctx | inbox: box}, next, ~U[2026-03-09 04:00:00Z])

    assert TestRepo.get!(Schedule, box.id, prefix: ctx.scope.prefix).delivery_date ==
             ~D[2026-03-08]
  end

  test "westward timezone change compares the previous UTC dispatch in the new zone", ctx do
    {:ok, box} = EmailJanitor.Inbox.new("travel", "travel@example.com")
    {:ok, _} = Store.add_inbox(ctx.scope, box)
    :ok = Digest.configure(ctx.scope, box.id, "Asia/Tokyo", ~U[2026-11-20 01:00:00Z])
    event(ctx.scope, box, 90, :done, ~U[2026-11-20 11:00:00Z])
    {:ok, {:ready, old}} = Digest.tick(ctx.scope, box.id, ~U[2026-11-20 12:00:00Z])
    assert :ok = send_digest(%{ctx | inbox: box}, old, ~U[2026-11-20 15:30:00Z])

    assert TestRepo.get!(Schedule, box.id, prefix: ctx.scope.prefix).delivery_date ==
             ~D[2026-11-21]

    :ok = Digest.configure(ctx.scope, box.id, "America/Los_Angeles", ~U[2026-11-20 16:00:00Z])
    event(ctx.scope, box, 91, :done, ~U[2026-11-20 20:00:00Z])
    assert {:ok, :daily_slot_used} = Digest.tick(ctx.scope, box.id, ~U[2026-11-21 05:00:00Z])
    assert {:ok, {:ready, next}} = Digest.tick(ctx.scope, box.id, ~U[2026-11-22 05:00:00Z])
    assert :ok = send_digest(%{ctx | inbox: box}, next, ~U[2026-11-22 05:00:00Z])

    assert TestRepo.get!(Schedule, box.id, prefix: ctx.scope.prefix).delivery_date ==
             ~D[2026-11-21]
  end

  test "ordinary escaped multipart replies quoting a full digest fit the inbound MIME cap", ctx do
    alias EmailJanitor.Digest.Renderer

    sender =
      String.duplicate("&", 64) <>
        "@" <>
        String.duplicate("b", 63) <>
        "." <> String.duplicate("c", 63) <> "." <> String.duplicate("d", 49) <> ".example.com"

    subject = String.duplicate("&<>=", 64)
    entry = %{kind: :done, sender: sender, subject: subject}
    entries = List.duplicate(entry, div(Renderer.metadata_budget(), Renderer.entry_bytes(entry)))
    {:ok, message} = Renderer.message(%{first: true}, entries, String.duplicate("&", 2048))
    body = Content.read(message.text)
    assert byte_size(body) > 28_000 and byte_size(body) <= Renderer.max_digest_bytes()
    reply = "Please keep Bob's email.\n\n" <> body

    html =
      Floki.raw_html([
        {"p", [], ["Please keep Bob's email."]},
        {"blockquote", [], [{"pre", [], [body]}]}
      ])

    mime =
      Mail.build_multipart()
      |> Mail.put_from(ctx.inbox.address)
      |> Mail.put_to("janitor@janitor.example.com")
      |> Mail.put_subject("Re: Email Janitor activity")
      |> Mail.put_text(reply)
      |> Mail.put_html(html)
      |> Mail.render()

    assert byte_size(mime) < 1_048_576

    config = %{
      F.config(fn _ -> flunk("unexpected transport") end)
      | test_plug: fn conn ->
          case conn.method do
            "HEAD" ->
              conn
              |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(mime)))
              |> Plug.Conn.send_resp(200, "")

            "GET" ->
              Plug.Conn.send_resp(conn, 200, mime)
          end
        end
    }

    assert {:ok, content} = EmailJanitor.Mail.SDK.fetch(config, "incoming/quoted-reply")
    assert byte_size(Content.read(content)) == byte_size(mime)
  end
end
