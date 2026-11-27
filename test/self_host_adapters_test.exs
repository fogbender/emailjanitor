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
      Digest.install_staging(scope)
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
end
