defmodule EmailJanitor.FeedbackFlowTest.Repo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.FeedbackFlowTest.Gmail do
  def feedback_sent(_, _, opts) do
    Agent.get_and_update(opts[:state], fn state ->
      result = if state.gmail == :ready, do: {:ok, state.sent}, else: {:error, :sent_not_indexed}
      {result, %{state | gmail_calls: state.gmail_calls + 1}}
    end)
  end
end

defmodule EmailJanitor.FeedbackFlowTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import ExUnit.CaptureLog
  alias EmailJanitor.{Content, Inbox, Message, Store}
  alias EmailJanitor.Mail.{Feedback, Incoming, Spool}
  alias EmailJanitor.Mail.Feedback.{Binding, Config, Context, Ledger, Record, Route}
  alias EmailJanitor.Store.Scope
  alias EmailJanitor.FeedbackFlowTest.{Repo, Gmail}
  alias EmailJanitor.MailFixture, as: F

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
    prefix = "ej_feedback_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    {:ok, scope} = Scope.new(Repo, prefix)
    {:ok, user_scope} = Scope.new(Repo, prefix <> "u")

    for s <- [scope, user_scope] do
      Store.install(s)
      EmailJanitor.Mail.Store.install(s)
    end

    :ok = Feedback.install(scope)
    {:ok, transport} = Inbox.new("transport", "janitor@janitor.example.com")
    {:ok, sender} = Inbox.new("sender-inbox", "owner@example.com")
    {:ok, _} = Store.add_inbox(scope, transport)
    {:ok, _} = Store.add_inbox(user_scope, sender)
    now = DateTime.utc_now()

    sent = %Message{
      id: "sent-1",
      thread_id: "thread-1",
      labels: ["SENT"],
      received_at: now,
      feedback_format: :plain,
      headers: [
        {"From", sender.address},
        {"To", transport.address},
        {"Subject", "Janitor"},
        {"Message-ID", "<command-1@example.com>"}
      ],
      body: Content.new("AUTHORED_SENT_INSTRUCTION")
    }

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             gmail: :ready,
             sent: sent,
             gmail_calls: 0,
             commands: [],
             deliveries: [],
             methods: [],
             ses: :ready,
             credentials: :ready
           }
         end}
      )

    mail =
      F.config(fn conn ->
        Agent.update(state, &%{&1 | methods: &1.methods ++ [conn.method]})

        case conn.method do
          "GET" ->
            Plug.Conn.send_resp(conn, 200, raw(sender.address))

          "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")

          "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(state, &%{&1 | deliveries: &1.deliveries ++ [URI.decode_query(body)]})

            if Agent.get(state, & &1.ses) == :ready,
              do: F.ses_response(conn),
              else: Plug.Conn.send_resp(conn, 503, "PRIVATE_PROVIDER_ERROR")
        end
      end)

    mail = %{
      mail
      | credentials: fn ->
          if Agent.get(state, & &1.credentials) == :ready,
            do:
              {:ok,
               [
                 access_key_id: "synthetic-access",
                 secret_access_key: "synthetic-secret",
                 security_token: "synthetic-token"
               ]},
            else: {:error, :temporarily_unavailable}
        end
    }

    conversation = Ecto.UUID.generate()

    context = %Context{
      key: "sender_context",
      scope: user_scope,
      inbox: sender,
      conversation_id: conversation,
      guard: fn -> :ok end,
      respond: fn id, authored, evidence ->
        Agent.update(
          state,
          &%{&1 | commands: &1.commands ++ [{id, Content.read(authored), evidence}]}
        )

        {:ok, Content.new("MODEL_REPLY_PROSE_SENTINEL")}
      end,
      render: fn _ -> {:ok, Content.new("VERIFIED_DURABLE_RESULT")} end
    }

    binding = %Binding{
      scope: user_scope,
      inbox: sender,
      gmail: {Gmail, [state: state]},
      guard: fn -> :ok end,
      route_verified: fn _ -> {:ok, context} end,
      restore_context: fn "sender_context" -> {:ok, context} end
    }

    {:ok, config} =
      Config.new(
        transport_scope: scope,
        transport_inbox: transport,
        mail: mail,
        parser_executable: System.find_executable("emailjanitor-reply-parser"),
        route: fn envelope ->
          if envelope.from == sender.address,
            do: {:ok, %Route{key: "sender_epoch_1", inbox_id: sender.id}},
            else: :unknown
        end,
        resolve: fn "sender_epoch_1" -> {:ok, binding} end,
        signup_url: "https://emailjanitor.net"
      )

    incoming = %Incoming{
      id: "ses-feedback",
      inbox_id: transport.id,
      object_key: "incoming/ses-feedback",
      envelope_from: sender.address,
      recipients: [transport.address],
      verdicts:
        Map.new(~w(spamVerdict virusVerdict spfVerdict dkimVerdict dmarcVerdict), &{&1, "PASS"}),
      expires_at: DateTime.add(now, 3600)
    }

    on_exit(fn ->
      for s <- [scope, user_scope],
          do:
            Ecto.Adapters.SQL.query!(Repo, ~s(DROP SCHEMA "#{s.prefix}" CASCADE), [], log: false)
    end)

    %{
      scope: scope,
      user_scope: user_scope,
      transport: transport,
      sender: sender,
      state: state,
      config: config,
      incoming: incoming,
      context: context,
      binding: binding
    }
  end

  defp raw(from, id \\ "command-1@example.com"),
    do:
      "From: " <>
        from <>
        "\r\nTo: janitor@janitor.example.com\r\nMessage-ID: <" <>
        id <> ">\r\nSubject: RAW_SUBJECT_IGNORED\r\n\r\nRAW_SMTP_BODY_MUST_NEVER_EXECUTE"

  defp accept(ctx, incoming \\ nil, body \\ nil),
    do:
      Feedback.accept(
        ctx.config,
        incoming || ctx.incoming,
        Content.new(body || raw(ctx.sender.address))
      )

  defp due(ctx, id),
    do:
      Repo.update_all(
        from(r in Record, where: r.id == ^id),
        [set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1)]],
        prefix: ctx.scope.prefix
      )

  test "SMTP body is never executed or stored; only the authenticated fresh Sent copy supplies the instruction",
       ctx do
    assert {:ok, id} = accept(ctx)
    assert Agent.get(ctx.state, & &1.gmail_calls) == 0
    logs = capture_log(fn -> assert {:ok, :completed} = Feedback.process(ctx.config, id) end)
    assert [{_request, "AUTHORED_SENT_INSTRUCTION", nil}] = Agent.get(ctx.state, & &1.commands)
    assert Ledger.get(ctx.scope, id).state == :completed
    assert [delivery] = Agent.get(ctx.state, & &1.deliveries)
    assert delivery["Destination.ToAddresses.member.1"] == ctx.sender.address
    assert delivery["Message.Body.Text.Data"] == "MODEL_REPLY_PROSE_SENTINEL"

    columns =
      Repo.all(Record, prefix: ctx.scope.prefix) |> Enum.map(&Map.from_struct/1) |> inspect()

    for sentinel <- ["AUTHORED_SENT_INSTRUCTION", "RAW_SMTP_BODY", "MODEL_REPLY_PROSE_SENTINEL"] do
      refute columns =~ sentinel
      refute logs =~ sentinel
    end
  end

  test "metadata acceptance purges S3 before a Sent-index retry and never needs SMTP content again",
       ctx do
    Agent.update(ctx.state, &%{&1 | gmail: :not_indexed})
    {receipt, _} = F.receipt(ctx.config.mail, "ses-spooled")
    {:ok, spool} = Spool.accept(ctx.scope, ctx.transport.id, receipt)

    assert :ok =
             Spool.process(
               ctx.scope,
               spool.id,
               ctx.config.mail,
               &Feedback.accept(ctx.config, &1, &2)
             )

    assert Spool.get(ctx.scope, spool.id).state == :deleted
    assert "DELETE" in Agent.get(ctx.state, & &1.methods)
    assert Agent.get(ctx.state, & &1.gmail_calls) == 0
    id = Spool.get(ctx.scope, spool.id).workflow_id
    assert {:ok, :deferred} = Feedback.tick(ctx.config)
    assert Ledger.get(ctx.scope, id).state == :waiting_sent
    Agent.update(ctx.state, &%{&1 | gmail: :ready})
    due(ctx, id)
    assert {:ok, :completed} = Feedback.tick(ctx.config)
    assert Enum.count(Agent.get(ctx.state, & &1.methods), &(&1 == "GET")) == 1
    assert length(Agent.get(ctx.state, & &1.commands)) == 1
  end

  test "duplicates retain the original expiry and cannot repeat workflow or reply", ctx do
    {:ok, id} = accept(ctx)
    original = Ledger.get(ctx.scope, id)
    assert {:ok, :completed} = Feedback.process(ctx.config, id)

    later = %{
      ctx.incoming
      | id: "ses-replay",
        expires_at: DateTime.add(ctx.incoming.expires_at, 300)
    }

    assert {:ok, ^id} = accept(ctx, later)
    assert Ledger.get(ctx.scope, id).expires_at == original.expires_at
    assert {:ok, :idle} = Feedback.tick(ctx.config)
    assert length(Agent.get(ctx.state, & &1.commands)) == 1
    assert length(Agent.get(ctx.state, & &1.deliveries)) == 1
  end

  test "a reply resumes from metadata without fetching Sent again or retaining model prose",
       ctx do
    Agent.update(ctx.state, &%{&1 | credentials: :unavailable})
    {:ok, id} = accept(ctx)
    assert {:ok, :deferred} = Feedback.process(ctx.config, id)
    assert Ledger.get(ctx.scope, id).state == :reply_pending
    Agent.update(ctx.state, &%{&1 | credentials: :ready, gmail: :not_indexed})
    due(ctx, id)
    assert {:ok, :completed} = Feedback.process(ctx.config, id)
    assert Agent.get(ctx.state, & &1.gmail_calls) == 1
    assert [{_, "AUTHORED_SENT_INSTRUCTION", nil}] = Agent.get(ctx.state, & &1.commands)
    assert [delivery] = Agent.get(ctx.state, & &1.deliveries)
    assert delivery["Message.Body.Text.Data"] == "VERIFIED_DURABLE_RESULT"
  end

  test "ambiguous SES acceptance is terminal and never resent", ctx do
    Agent.update(ctx.state, &%{&1 | ses: :timeout})
    {:ok, id} = accept(ctx)
    assert {:ok, :unresolved} = Feedback.process(ctx.config, id)
    Agent.update(ctx.state, &%{&1 | ses: :ready})
    assert {:ok, :idle} = Feedback.tick(ctx.config)
    assert length(Agent.get(ctx.state, & &1.deliveries)) == 1
  end

  test "HTML-only or ambiguous forwards clarify without calling the workflow", ctx do
    Agent.update(ctx.state, &%{&1 | sent: %{&1.sent | feedback_format: :html}})
    {:ok, id} = accept(ctx)
    assert {:ok, :completed} = Feedback.process(ctx.config, id)
    assert Agent.get(ctx.state, & &1.commands) == []
    assert [delivery] = Agent.get(ctx.state, & &1.deliveries)
    assert delivery["Message.Body.Text.Data"] =~ "separate your note"
  end

  test "authenticated missing context clarifies without running a guessed conversation", ctx do
    binding = %{ctx.binding | route_verified: fn _ -> {:clarify, ctx.context} end}
    config = %{ctx.config | resolve: fn _ -> {:ok, binding} end}
    {:ok, id} = accept(%{ctx | config: config})
    assert {:ok, :completed} = Feedback.process(config, id)
    assert Agent.get(ctx.state, & &1.commands) == []
    assert Ledger.get(ctx.scope, id).outcome == :clarify_unsupported
  end

  test "a temporary routing failure retains the spool for bounded retry instead of dropping the request",
       ctx do
    config = %{ctx.config | route: fn _ -> {:error, :database_temporarily_unavailable} end}
    assert {:error, :feedback_unavailable} = accept(%{ctx | config: config})
    assert Repo.all(Record, prefix: ctx.scope.prefix) == []
  end

  test "a temporary connection lookup retries, but a revoked binding never invokes the workflow",
       ctx do
    {:ok, id} = accept(ctx)
    temporary = %{ctx.config | resolve: fn _ -> {:error, :connection_unavailable} end}
    assert {:ok, :deferred} = Feedback.process(temporary, id)
    assert Ledger.get(ctx.scope, id).state == :waiting_sent
    due(ctx, id)
    revoked_binding = %{ctx.binding | guard: fn -> {:error, :connection_changed} end}
    revoked = %{ctx.config | resolve: fn _ -> {:ok, revoked_binding} end}
    assert {:ok, :rejected} = Feedback.process(revoked, id)
    assert Agent.get(ctx.state, & &1.commands) == []
  end

  test "a command context in another scope is rejected after authentication", ctx do
    foreign = %{ctx.context | scope: ctx.scope}
    binding = %{ctx.binding | route_verified: fn _ -> {:ok, foreign} end}
    config = %{ctx.config | resolve: fn _ -> {:ok, binding} end}
    {:ok, id} = accept(%{ctx | config: config})
    assert {:ok, :rejected} = Feedback.process(config, id)
    assert Agent.get(ctx.state, & &1.commands) == []
    assert Agent.get(ctx.state, & &1.deliveries) == []
  end

  test "unknown human signup is bounded per sender/day, loop protected and needs no Gmail account",
       ctx do
    stranger = "visitor@other.com"
    incoming = %{ctx.incoming | envelope_from: stranger}
    {:ok, id} = accept(ctx, incoming, raw(stranger))
    assert Ledger.get(ctx.scope, id).kind == :signup

    assert {:ok, ^id} =
             accept(ctx, %{incoming | id: "another-ses"}, raw(stranger, "another@example.com"))

    assert {:ok, :completed} = Feedback.process(ctx.config, id)
    assert Agent.get(ctx.state, & &1.gmail_calls) == 0
    assert [delivery] = Agent.get(ctx.state, & &1.deliveries)
    assert delivery["Destination.ToAddresses.member.1"] == stranger
    assert delivery["Message.Body.Text.Data"] =~ "https://emailjanitor.net"

    assert :ignored =
             accept(
               ctx,
               %{incoming | verdicts: Map.put(incoming.verdicts, "dmarcVerdict", "FAIL")},
               raw("other@other.com")
             )

    auto = String.replace(raw(stranger), "\r\n\r\n", "\r\nAuto-Submitted: auto-replied\r\n\r\n")
    assert :ignored = accept(ctx, incoming, auto)
  end

  test "long verified Janitor reply quotes can be omitted without discarding the clean authored request",
       ctx do
    context = %{ctx.context | verified_reference: true}
    binding = %{ctx.binding | route_verified: fn _ -> {:ok, context} end}
    config = %{ctx.config | resolve: fn _ -> {:ok, binding} end}

    body =
      "Keep Bob in my inbox.\n\nOn Thu, Nov 26, Janitor <janitor@janitor.example.com> wrote:\n" <>
        String.duplicate("> A long daily email entry.\n", 600)

    Agent.update(ctx.state, &%{&1 | sent: %{&1.sent | body: Content.new(body)}})
    {:ok, id} = accept(%{ctx | config: config})
    assert {:ok, :completed} = Feedback.process(config, id)
    assert Ledger.get(ctx.scope, id).outcome == :processed
    assert [{_, "Keep Bob in my inbox.", nil}] = Agent.get(ctx.state, & &1.commands)
  end

  test "oversize or unreadable parser input clarifies once instead of repeatedly fetching the body",
       ctx do
    Agent.update(
      ctx.state,
      &%{&1 | sent: %{&1.sent | body: Content.new(String.duplicate("x", 128_001))}}
    )

    {:ok, id} = accept(ctx)
    assert {:ok, :completed} = Feedback.process(ctx.config, id)
    assert Ledger.get(ctx.scope, id).outcome == :clarify_unsupported
    assert Agent.get(ctx.state, & &1.commands) == []
    assert {:ok, :idle} = Feedback.tick(ctx.config)
    assert Agent.get(ctx.state, & &1.gmail_calls) == 1
  end

  test "spoofed failed-DMARC hints are ignored and concurrent known-sender admission is bounded",
       ctx do
    failed = %{ctx.incoming | verdicts: Map.put(ctx.incoming.verdicts, "dmarcVerdict", "FAIL")}
    assert :ignored = accept(ctx, failed)
    assert Repo.all(Record, prefix: ctx.scope.prefix) == []

    results =
      1..25
      |> Task.async_stream(
        fn n ->
          accept(
            ctx,
            %{ctx.incoming | id: "ses-cap-#{n}"},
            raw(ctx.sender.address, "cap-#{n}@example.com")
          )
        end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 20
    assert Enum.count(results, &(&1 == :ignored)) == 5

    claims =
      1..20
      |> Task.async_stream(fn _ -> Ledger.claim_next(ctx.scope, DateTime.utc_now()) end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, row, _}} -> row.id end)

    assert length(Enum.uniq(claims)) == 20
    assert Agent.get(ctx.state, & &1.gmail_calls) == 0
  end

  test "pending reply expiry preserves the actual processed outcome and does not resend late",
       ctx do
    Agent.update(ctx.state, &%{&1 | credentials: :unavailable})
    {:ok, id} = accept(ctx)
    assert {:ok, :deferred} = Feedback.process(ctx.config, id)

    Repo.update_all(
      from(r in Record, where: r.id == ^id),
      [set: [authenticated_at: DateTime.add(DateTime.utc_now(), -7200)]],
      prefix: ctx.scope.prefix
    )

    due(ctx, id)
    assert {:ok, :expired} = Feedback.process(ctx.config, id)
    row = Ledger.get(ctx.scope, id)
    assert row.state == :expired and row.outcome == :processed
    assert Agent.get(ctx.state, & &1.gmail_calls) == 1
    assert length(Agent.get(ctx.state, & &1.commands)) == 1
  end

  test "signup can send again on a later UTC day without recreating its transport recipient",
       ctx do
    stranger = "repeat-visitor@example.net"
    incoming = %{ctx.incoming | envelope_from: stranger}
    {:ok, today_id} = accept(ctx, incoming, raw(stranger))
    first = Ledger.get(ctx.scope, today_id)
    yesterday = DateTime.add(first.received_at, -86400)

    {:ok, yesterday_id} =
      EmailJanitor.Mail.RFCMessageID.request_id(
        first.sender_inbox_id,
        "signup-" <> Date.to_iso8601(DateTime.to_date(yesterday)) <> "@emailjanitor.invalid"
      )

    Repo.update_all(
      from(r in Record, where: r.id == ^today_id),
      [
        set: [
          id: yesterday_id,
          received_at: yesterday,
          expires_at: DateTime.add(first.expires_at, -86400)
        ]
      ],
      prefix: ctx.scope.prefix
    )

    assert {:ok, ^today_id} =
             accept(ctx, %{incoming | id: "ses-next-day"}, raw(stranger, "next-day@example.net"))

    assert {:ok, :completed} = Feedback.process(ctx.config, today_id)
    assert length(Agent.get(ctx.state, & &1.deliveries)) == 1

    assert Repo.aggregate(from(m in Store.Mailbox, where: m.id == ^first.sender_inbox_id), :count,
             prefix: ctx.scope.prefix
           ) == 1
  end

  test "metadata purge removes stale claims and old signup recipients but preserves a live claim",
       ctx do
    stranger = "purge-visitor@example.net"
    {:ok, signup_id} = accept(ctx, %{ctx.incoming | envelope_from: stranger}, raw(stranger))
    assert {:ok, :completed} = Feedback.process(ctx.config, signup_id)
    signup = Ledger.get(ctx.scope, signup_id)
    {:ok, stale_id} = accept(ctx)

    {:ok, live_id} =
      accept(ctx, %{ctx.incoming | id: "ses-live"}, raw(ctx.sender.address, "live@example.com"))

    old = DateTime.add(DateTime.utc_now(), -8 * 86400)

    Repo.update_all(
      from(r in Record, where: r.id in ^[signup_id, stale_id, live_id]),
      [set: [inserted_at: old]],
      prefix: ctx.scope.prefix
    )

    Repo.update_all(
      from(r in Record, where: r.id == ^stale_id),
      [set: [state: :processing, lease_until: DateTime.add(DateTime.utc_now(), -1)]],
      prefix: ctx.scope.prefix
    )

    Repo.update_all(
      from(r in Record, where: r.id == ^live_id),
      [set: [state: :processing, lease_until: DateTime.add(DateTime.utc_now(), 1000)]],
      prefix: ctx.scope.prefix
    )

    Repo.update_all(EmailJanitor.Mail.Outgoing, [set: [inserted_at: old]],
      prefix: ctx.scope.prefix
    )

    assert :ok = Ledger.purge(ctx.scope, DateTime.utc_now())
    assert Ledger.get(ctx.scope, signup_id) == nil
    assert Ledger.get(ctx.scope, stale_id) == nil
    assert Ledger.get(ctx.scope, live_id)
    assert Repo.get(Store.Mailbox, signup.sender_inbox_id, prefix: ctx.scope.prefix) == nil
    assert Repo.all(EmailJanitor.Mail.Outgoing, prefix: ctx.scope.prefix) == []
  end
end
