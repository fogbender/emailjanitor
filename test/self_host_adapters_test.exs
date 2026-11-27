defmodule EmailJanitor.SelfHostSyntheticHoldPolicy do
  @behaviour EmailJanitor.Policy
  def reserve(_, _, _, _, _), do: {:blocked, :synthetic_hold}
  def settle(_, _, _, _), do: :ok
  def retire_candidate(_, _, _, _), do: :ok
end

defmodule EmailJanitor.SelfHostAdaptersTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Content, Digest, Executor, Reviewer, SelfHost, TestClassifier, TestGmail}
  alias EmailJanitor.Conversation.Reference
  alias EmailJanitor.Google.OAuth

  alias EmailJanitor.SelfHost.{
    ActivityPolicy,
    Adapters,
    Authority,
    Binding,
    Config,
    Grant,
    Repo,
    Runtime
  }

  alias EmailJanitor.SelfHost.Store, as: HostStore
  alias EmailJanitor.Store, as: CoreStore
  alias EmailJanitor.Digest.{Activity, Staged}

  setup_all do
    start_supervised!(
      {Repo,
       socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
       database: "emailjanitor_test",
       username: System.fetch_env!("USER"),
       port: 5432,
       pool: Ecto.Adapters.SQL.Sandbox,
       pool_size: 8,
       log: false}
    )

    scope = SelfHost.scope()

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      CoreStore.install(scope)
      EmailJanitor.Preferences.install(scope)
      EmailJanitor.Mail.Store.install(scope)
      Digest.install(scope)
      EmailJanitor.Gmail.Ingestion.install(scope)
      EmailJanitor.Worker.install(scope)
      Digest.install_staging(scope)
      EmailJanitor.Mail.Feedback.install(scope)
      HostStore.install(scope)
      Ecto.Migrator.up(Repo, 102, SelfHost.AuthorityMigration, prefix: scope.prefix, log: false)
    end)

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    old = Application.get_env(:email_janitor, :self_host_config)

    config = %Config{
      owner_email: "owner@example.com",
      public_url: "https://janitor.example.com",
      credential_key: Content.new(:crypto.strong_rand_bytes(32)),
      web_secret: Content.new(String.duplicate("s", 64)),
      reply_parser_executable: System.find_executable("emailjanitor-reply-parser"),
      mail: %{
        "JANITOR_MAIL_SENDER" => "janitor@janitor.example.com",
        "JANITOR_MAIL_BUCKET" => "janitor-spool",
        "JANITOR_MAIL_QUEUE_URL" => "https://sqs.us-east-1.amazonaws.com/123456789012/janitor",
        "JANITOR_MAIL_TOPIC_ARN" => "arn:aws:sns:us-east-1:123456789012:janitor"
      },
      pubsub: %{"JANITOR_GOOGLE_TOPIC" => "projects/janitor-project/topics/gmail"}
    }

    Application.put_env(:email_janitor, :self_host_config, config)

    on_exit(fn ->
      if old,
        do: Application.put_env(:email_janitor, :self_host_config, old),
        else: Application.delete_env(:email_janitor, :self_host_config)
    end)

    result = %OAuth.Result{
      subject: "owner-sub",
      email: "owner@example.com",
      token:
        Content.new(
          Jason.encode!(%{
            "access_token" => "PRIVATE_ADAPTER_TOKEN",
            "refresh_token" => "PRIVATE_ADAPTER_REFRESH",
            "token_type" => "Bearer",
            "expires_at" => System.system_time(:second) + 3600,
            "scope" => "https://www.googleapis.com/auth/gmail.modify"
          })
        )
    }

    {:ok, owner} = SelfHost.authorize_owner(result)
    {:ok, box} = SelfHost.connect(owner, result, "Etc/UTC")
    binding = Repo.get!(Binding, box.id, prefix: SelfHost.scope().prefix)
    ref = {box.id, binding.epoch}
    :ok = HostStore.activate(ref)
    %{scope: SelfHost.scope(), box: box, ref: ref, owner: owner, config: config, result: result}
  end

  defp proposal(messages, ctx) do
    Reviewer.review(messages, ctx.box, MapSet.new(), {TestClassifier, []}, "", 1)
  end

  defp reference(ctx, id) do
    {:ok, ref} = Reference.new(ctx.box.id, id, "thread-1", "sender@vendor.com", "Subject " <> id)
    ref
  end

  test "fresh metadata policy stages actual Done and does not retain bodies", ctx do
    message =
      message(
        id: "m1",
        headers: [{"From", "Sales <sales@vendor.com>"}, {"Subject", "Selected subject"}],
        body: "PRIVATE_POLICY_BODY"
      )

    unselected =
      message(id: "draft1", headers: [], labels: ["DRAFT"], body: "PRIVATE_UNSELECTED_BODY")

    {:ok, policy} = ActivityPolicy.for_messages(ctx.ref, ctx.box, [message, unselected])
    refute inspect(policy.context) =~ "PRIVATE_POLICY_BODY"
    refute inspect(policy.context) =~ "PRIVATE_UNSELECTED_BODY"
    assert Map.keys(policy.context.metadata) == ["m1"]
    {:ok, proposal} = proposal([message], ctx)
    state = start_supervised!({Agent, fn -> %{messages: [message], contacted: [], calls: []} end})

    assert {:done, action} =
             Executor.execute(ctx.scope, ctx.box, proposal, {TestGmail, [state: state]},
               policy: policy
             )

    assert [%Activity{source_id: ^action, message_id: "m1", subject: "Selected subject"}] =
             Repo.all(Activity, prefix: ctx.scope.prefix)

    assert Repo.all(Staged, prefix: ctx.scope.prefix) == []
    assert Agent.get(state, & &1.calls) == [["m1"]]
  end

  test "durable settlement still records Done after credentials disappear without another Gmail call",
       ctx do
    message = message(id: "m1", from: "sender@vendor.com")
    {:ok, policy} = ActivityPolicy.for_messages(ctx.ref, ctx.box, [message])
    {:ok, proposal} = proposal([message], ctx)

    {:ok, {:created, action}} =
      CoreStore.intent(ctx.scope, ctx.box.id, proposal, "100", policy: policy)

    :ok = CoreStore.transition(ctx.scope, ctx.box.id, action.id, :intent, :done)
    :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)

    assert {:existing, _, :done} =
             Executor.settle_action(ctx.scope, ctx.box, action.id,
               policy: ActivityPolicy.settlement(ctx.ref, ctx.box)
             )

    assert [%Activity{message_id: "m1"}] = Repo.all(Activity, prefix: ctx.scope.prefix)
    assert Repo.get!(Binding, ctx.box.id, prefix: ctx.scope.prefix).token_ciphertext == nil
  end

  test "manual recheck needs an authenticated host grant for every selected ID", ctx do
    request = Ecto.UUID.generate()
    conversation = Ecto.UUID.generate()
    refs = [reference(ctx, "m1"), reference(ctx, "m2")]
    assert {:error, :manual_authorization_changed} = Authority.allow(ctx.ref, request, ["m1"])

    assert {:error, :manual_authorization_changed} =
             Authority.record(ctx.ref, "other", conversation, request, :done, refs)

    assert :ok = Authority.record(ctx.ref, ctx.owner, conversation, request, :done, refs)
    assert :ok = Authority.allow(ctx.ref, request, ["m1", "m2"])

    assert {:error, :manual_authorization_changed} =
             Authority.allow(ctx.ref, request, ["m1", "m3"])

    assert :ok = Authority.record(ctx.ref, ctx.owner, conversation, request, :done, [hd(refs)])

    assert {:error, :manual_authorization_changed} =
             Authority.record(ctx.ref, ctx.owner, conversation, request, :done, [
               reference(ctx, "m3")
             ])

    assert Repo.aggregate(Grant, :count, prefix: ctx.scope.prefix) == 1
    :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert {:error, :manual_authorization_changed} = Authority.allow(ctx.ref, request, ["m1"])
    assert {:ok, _} = SelfHost.connect(ctx.owner, ctx.result, "Etc/UTC")
    binding = Repo.get!(Binding, ctx.box.id, prefix: ctx.scope.prefix)

    assert {:error, :manual_authorization_changed} =
             Authority.allow({ctx.box.id, binding.epoch}, request, ["m1"])
  end

  test "trusted Context derives SDK/config/scope internally and records only admitted metadata",
       ctx do
    conversation = Ecto.UUID.generate()

    assert {:error, :conversation_unavailable} =
             Runtime.context("other", ctx.box.id, conversation)

    assert {:ok, context} = Runtime.context(ctx.owner, ctx.box.id, conversation)
    assert context.scope == ctx.scope
    assert context.inbox == ctx.box
    assert {EmailJanitor.Gmail.SDK, [config: gmail]} = context.gmail
    assert gmail.inbox == ctx.box
    assert context.model[:config].provider == :bedrock
    assert :ok = context.guard.()
    request = Ecto.UUID.generate()

    assert :ok =
             context.execution_options[:on_plan_admitted].(request, :done, [reference(ctx, "m1")])

    assert :ok = Authority.allow(ctx.ref, request, ["m1"])

    assert %EmailJanitor.Policy{} =
             context.execution_options[:policy_for_references].([reference(ctx, "m1")])

    assert {:ok, scope, inbox} = Adapters.route(ctx.box.address)
    assert scope == ctx.scope and inbox == ctx.box
    :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert {:error, :inbox_unavailable} = context.guard.()
    assert {:ignore, :disconnected} = Adapters.route(ctx.box.address)
  end

  test "mail spool anchor cannot appear as a connected Google cleanup inbox", ctx do
    assert :ok = SelfHost.Transport.install(ctx.config)
    assert :ok = SelfHost.Transport.install(ctx.config)
    assert {:ok, transport} = SelfHost.Transport.inbox(ctx.config)

    assert Repo.get!(EmailJanitor.Store.Mailbox, transport.id, prefix: ctx.scope.prefix).address ==
             "janitor@janitor.example.com"

    assert Repo.get(Binding, transport.id, prefix: ctx.scope.prefix) == nil
    assert {:error, :inbox_unavailable} = SelfHost.inbox(ctx.owner, transport.id)
    assert {:ok, refs} = HostStore.refs()
    refute Enum.any?(refs, fn {id, _} -> id == transport.id end)

    changed = %{
      ctx.config
      | mail: Map.put(ctx.config.mail, "JANITOR_MAIL_SENDER", "different@janitor.example.com")
    }

    assert {:error, :transport_unavailable} = SelfHost.Transport.install(changed)
  end

  test "exact partial retirement preserves the remaining arrival candidate's executable proof",
       ctx do
    alias EmailJanitor.Gmail.Ingestion
    alias EmailJanitor.Worker.{Candidate, Ledger}

    {:ok, checkpoint} =
      Ingestion.baseline(ctx.scope, ctx.box, %{
        history_id: "100",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    messages = [
      message(id: "m1", from: "sender@vendor.com"),
      message(id: "m2", from: "sender@vendor.com")
    ]

    {:ok, proposal} = proposal(messages, ctx)
    hold = %EmailJanitor.Policy{adapter: EmailJanitor.SelfHostSyntheticHoldPolicy, context: nil}

    assert {:ok, {:blocked, :synthetic_hold}} =
             CoreStore.intent(ctx.scope, ctx.box.id, proposal, "100", policy: hold)

    pending = Repo.one!(EmailJanitor.Store.Candidate, prefix: ctx.scope.prefix)

    :ok =
      Ledger.record_candidate(
        ctx.scope,
        ctx.box,
        pending.id,
        proposal,
        checkpoint.generation,
        DateTime.utc_now(),
        true
      )

    policy = ActivityPolicy.settlement(ctx.ref, ctx.box)

    assert {:ok, :retired} =
             CoreStore.retire_ineligible(
               ctx.scope,
               ctx.box.id,
               proposal.thread_id,
               1,
               DateTime.add(DateTime.utc_now(), 1),
               policy: policy,
               evaluated_message_ids: ["m1"],
               inbox_message_ids: ["m1", "m2"]
             )

    assert Repo.get!(EmailJanitor.Store.Candidate, pending.id, prefix: ctx.scope.prefix).remaining_message_ids ==
             ["m2"]

    source =
      Repo.get_by!(Candidate, [inbox_id: ctx.box.id, candidate_id: pending.id],
        prefix: ctx.scope.prefix
      )

    assert source.message_ids == ["m2"]
    assert source.status == :pending and source.source_kind == :arrival
    assert :ok = Ledger.candidate_available?(ctx.scope, ctx.box, source, checkpoint.generation)
    {:ok, fresh} = proposal([List.last(messages)], ctx)

    assert :ok =
             Ledger.authorize_candidate(ctx.scope, ctx.box, source, fresh, checkpoint.generation)

    # Gate double-forwarding is idempotent and cannot reintroduce the removed ID.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               ActivityPolicy.retire_candidate_messages(policy.context, ctx.box.id, pending.id, [
                 "m1"
               ])
             end)

    assert Repo.get_by!(Candidate, [inbox_id: ctx.box.id, candidate_id: pending.id],
             prefix: ctx.scope.prefix
           ).message_ids == ["m2"]
  end

  defp envelope(address) do
    now = DateTime.utc_now()

    %EmailJanitor.Mail.Feedback.Envelope{
      ses_id: "ses-route",
      from: address,
      rfc_message_id: "route@example.com",
      received_at: now,
      expires_at: DateTime.add(now, 3600),
      signup_allowed: false
    }
  end

  test "email context routes only verified connected metadata and fences sender epoch", ctx do
    alias EmailJanitor.SelfHost.Email
    {:ok, route} = Email.route(envelope(ctx.box.address))
    {:ok, binding} = Email.resolve(ctx.config, route.key)
    sent = message(id: "sent-1", headers: [{"From", ctx.box.address}], body: "PRIVATE_SENT_BODY")
    assert {:ok, first} = binding.route_verified.(sent)
    assert first.inbox == ctx.box
    assert {:ok, again} = binding.route_verified.(%{sent | id: "sent-2"})
    assert first.conversation_id == again.conversation_id
    assert {:ok, restored} = binding.restore_context.(first.key)
    assert restored.conversation_id == first.conversation_id
    assert :ok = restored.guard.()
    assert :binary.match(:erlang.term_to_binary(first), "PRIVATE_SENT_BODY") == :nomatch
    assert :unknown = Email.route(envelope("unconnected@example.net"))
    assert {:error, :feedback_connection_changed} = Email.resolve(ctx.config, "malformed")
    assert :ok = SelfHost.disconnect(ctx.owner, ctx.box.id)
    assert {:error, _} = binding.restore_context.(first.key)
    assert {:error, :feedback_connection_changed} = Email.resolve(ctx.config, route.key)
  end

  test "recorded digest references select the command inbox and retain rename proof", ctx do
    alias EmailJanitor.SelfHost.Email
    alias EmailJanitor.Mail.{Outbox, Outgoing}
    other_result = %{ctx.result | subject: "other-subject", email: "other@example.com"}
    {:ok, other} = SelfHost.connect(ctx.owner, other_result, "Etc/UTC")
    binding = Repo.get!(Binding, other.id, prefix: ctx.scope.prefix)
    :ok = HostStore.activate({other.id, binding.epoch})
    snapshot_id = Ecto.UUID.generate()
    {:ok, outgoing} = Outbox.enqueue(ctx.scope, other.id, :digest, [snapshot_id], snapshot_id)

    Repo.insert!(
      %Digest.Snapshot{
        id: snapshot_id,
        inbox_id: other.id,
        timezone: "Etc/UTC",
        local_date: Date.utc_today(),
        cutoff: DateTime.utc_now(),
        outbox_id: outgoing.id
      },
      prefix: ctx.scope.prefix
    )

    Repo.update!(
      Ecto.Changeset.change(outgoing,
        state: :sent,
        provider_id: "digest-proof",
        sender: "janitor@janitor.example.com",
        recipient: other.address
      ),
      prefix: ctx.scope.prefix
    )

    {:ok, renamed} =
      SelfHost.connect(ctx.owner, %{other_result | email: "renamed@example.com"}, "Etc/UTC")

    {:ok, route} = Email.route(envelope(ctx.box.address))
    {:ok, sender} = Email.resolve(ctx.config, route.key)

    sent =
      message(
        headers: [{"In-Reply-To", "<digest-proof@email.amazonses.com>"}],
        body: "PRIVATE_FORWARDED_BODY"
      )

    assert {:ok, context} = sender.route_verified.(sent)
    assert context.inbox == renamed
    assert context.conversation_id == snapshot_id
    Repo.update_all(Outgoing, [set: [state: :unresolved]], prefix: ctx.scope.prefix)
    assert {:clarify, fallback} = sender.route_verified.(sent)
    assert fallback.inbox == ctx.box
  end

  test "intake acknowledges durable metadata then a restarted processor purges raw mail before Sent lookup",
       ctx do
    alias EmailJanitor.SelfHost.{Email, Transport}
    alias EmailJanitor.Mail.Receiver, as: MailJobs
    alias EmailJanitor.Mail.{Incoming, Spool}
    alias EmailJanitor.Mail.Feedback.Record
    alias EmailJanitor.MailFixture, as: F
    :ok = Transport.install(ctx.config)
    {:ok, initial} = Email.config(ctx.config)
    dummy = F.config(fn _ -> flunk("unused") end)
    {_receipt, json} = F.receipt(dummy, "ses-intake")
    notification = Jason.encode!(json)
    test_pid = self()

    raw =
      "From: owner@example.com\r\nTo: janitor@janitor.example.com\r\nSubject: Cleanup\r\nMessage-ID: <intake@example.com>\r\n\r\nPRIVATE_SMTP_COMMAND_BODY"

    mail =
      F.config(fn conn ->
        case conn.method do
          "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            case URI.decode_query(body)["Action"] do
              "ReceiveMessage" ->
                Plug.Conn.send_resp(
                  conn,
                  200,
                  "<ReceiveMessageResponse><ReceiveMessageResult><Message><MessageId>q1</MessageId><ReceiptHandle>handle1</ReceiptHandle><Body>#{notification}</Body><MD5OfBody>x</MD5OfBody></Message></ReceiveMessageResult></ReceiveMessageResponse>"
                )

              "DeleteMessage" ->
                assert %Incoming{state: :pending} = Spool.get(ctx.scope, "ses-intake")
                send(test_pid, :ack_after_durable_accept)

                Plug.Conn.send_resp(
                  conn,
                  200,
                  "<DeleteMessageResponse><ResponseMetadata><RequestId>r1</RequestId></ResponseMetadata></DeleteMessageResponse>"
                )
            end

          "GET" ->
            send(test_pid, :raw_read)
            Plug.Conn.send_resp(conn, 200, raw)

          "DELETE" ->
            assert %Record{source_ses_id: "ses-intake"} =
                     Repo.one(Record, prefix: ctx.scope.prefix)

            send(test_pid, :raw_deleted_after_feedback_record)
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

    config = %{
      initial
      | mail: mail,
        resolve: fn _ -> flunk("Sent lookup must wait for separate feedback job") end
    }

    assert {:next, nil, 1000} = MailJobs.receive_once(config)
    assert_received :ack_after_durable_accept
    refute_received :raw_read
    assert %Incoming{state: :pending} = Spool.get(ctx.scope, "ses-intake")
    assert {:next, nil, 0} = MailJobs.process_once(config)
    assert_received :raw_read
    assert_received :raw_deleted_after_feedback_record
    assert %Incoming{state: :deleted} = Spool.get(ctx.scope, "ses-intake")
    row = Repo.one!(Record, prefix: ctx.scope.prefix)
    assert :binary.match(:erlang.term_to_binary(row), "PRIVATE_SMTP_COMMAND_BODY") == :nomatch
    assert Repo.aggregate(EmailJanitor.Mail.Outgoing, :count, prefix: ctx.scope.prefix) == 0
    assert {:next, nil, 1000} = MailJobs.process_once(config)
  end
end
