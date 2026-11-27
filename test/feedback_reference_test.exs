defmodule EmailJanitor.FeedbackReferenceTest.Repo do
  use Ecto.Repo, otp_app: :email_janitor, adapter: Ecto.Adapters.Postgres
end

defmodule EmailJanitor.FeedbackReferenceTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.{Inbox, Store}
  alias EmailJanitor.Mail.{Outgoing, Feedback.Reference}
  alias EmailJanitor.Store.Scope
  alias EmailJanitor.FeedbackReferenceTest.Repo
  @sender "janitor@janitor.example.com"

  setup_all do
    start_supervised!(
      {Repo,
       [
         socket_dir: System.fetch_env!("JANITOR_TEST_SOCKET"),
         database: "emailjanitor_test",
         username: System.fetch_env!("USER"),
         port: 5432,
         pool_size: 4,
         log: false
       ]}
    )

    :ok
  end

  setup do
    prefix = "ej_reference_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

    scopes =
      for suffix <- ["a", "b"] do
        {:ok, scope} = Scope.new(Repo, prefix <> suffix)
        Store.install(scope)
        EmailJanitor.Mail.Store.install(scope)
        {:ok, inbox} = Inbox.new("inbox", "owner@example.com")
        {:ok, _} = Store.add_inbox(scope, inbox)
        scope
      end

    on_exit(fn ->
      for scope <- scopes,
          do:
            Ecto.Adapters.SQL.query!(Repo, ~s(DROP SCHEMA "#{scope.prefix}" CASCADE), [],
              log: false
            )
    end)

    %{scope: hd(scopes), foreign: List.last(scopes)}
  end

  defp outgoing(scope, provider, opts \\ []) do
    Repo.insert!(
      %Outgoing{
        inbox_id: "inbox",
        kind: :assistant,
        reference_ids: [Ecto.UUID.generate()],
        dedupe_id: Ecto.UUID.generate(),
        state: opts[:state] || :sent,
        provider_id: provider,
        sender: opts[:sender] || @sender,
        recipient: opts[:recipient] || "owner@example.com"
      },
      prefix: scope.prefix
    )
  end

  test "only exact confirmed evidence in this scope routes a fresh Sent reply", ctx do
    own = outgoing(ctx.scope, "ses-own")
    outgoing(ctx.foreign, "ses-foreign")

    assert {:ok, %{inbox_id: "inbox", reference_ids: refs}} =
             Reference.delivery(ctx.scope, @sender, [
               {"In-Reply-To", "<ses-own@us-east-1.amazonses.com>"}
             ])

    assert refs == own.reference_ids

    assert {:error, :unverified_reply_reference} =
             Reference.delivery(ctx.scope, @sender, [
               {"In-Reply-To", "<ses-foreign@us-east-1.amazonses.com>"}
             ])

    assert {:ok, :none} =
             Reference.delivery(ctx.scope, @sender, [{"References", "<not-janitor@example.com>"}])

    outgoing(ctx.scope, "ses-pending", state: :unresolved)
    outgoing(ctx.scope, "ses-other-sender", sender: "different@example.com")

    for id <- ["ses-pending", "ses-other-sender"] do
      assert {:error, :unverified_reply_reference} =
               Reference.delivery(ctx.scope, @sender, [{"In-Reply-To", "<#{id}@amazonses.com>"}])
    end
  end

  test "current reply target wins over older references; duplicate and ambiguous headers never pick a context",
       ctx do
    old = outgoing(ctx.scope, "ses-old")
    current = outgoing(ctx.scope, "ses-current")

    assert {:ok, %{reference_ids: refs}} =
             Reference.delivery(ctx.scope, @sender, [
               {"In-Reply-To", "<ses-current@amazonses.com>"},
               {"References", "<ses-old@amazonses.com>"}
             ])

    assert refs == current.reference_ids and refs != old.reference_ids

    assert {:error, :ambiguous_reply_reference} =
             Reference.delivery(ctx.scope, @sender, [
               {"References", "<ses-old@amazonses.com> <ses-current@amazonses.com>"}
             ])

    assert {:error, :ambiguous_reply_reference} =
             Reference.delivery(ctx.scope, @sender, [
               {"In-Reply-To", "<ses-old@amazonses.com>"},
               {"In-Reply-To", "<ses-current@amazonses.com>"}
             ])

    assert {:error, :unverified_reply_reference} =
             Reference.delivery(ctx.scope, @sender, [
               {"In-Reply-To", "<unknown@amazonses.com>"},
               {"References", "<ses-old@amazonses.com>"}
             ])
  end

  test "renamed recipient needs exact subject-bound host history; normalization alone is not evidence",
       ctx do
    outgoing(ctx.scope, "ses-historical", recipient: "old@example.com")
    headers = [{"In-Reply-To", "<ses-historical@amazonses.com>"}]
    assert {:error, :unverified_reply_reference} = Reference.delivery(ctx.scope, @sender, headers)

    assert {:ok, %{inbox_id: "inbox"}} =
             Reference.delivery(ctx.scope, @sender, headers, fn "inbox", "old@example.com" ->
               true
             end)

    assert {:error, :unverified_reply_reference} =
             Reference.delivery(ctx.scope, @sender, headers, fn _, _ -> false end)

    outgoing(ctx.scope, "ses-tampered", recipient: "tampered@example.com")

    assert {:error, :unverified_reply_reference} =
             Reference.delivery(
               ctx.scope,
               @sender,
               [{"In-Reply-To", "<ses-tampered@amazonses.com>"}],
               fn _, addr -> addr == "old@example.com" end
             )

    outgoing(ctx.scope, "ses-not-normalized", recipient: "Old@example.com")

    assert {:error, :unverified_reply_reference} =
             Reference.delivery(
               ctx.scope,
               @sender,
               [{"In-Reply-To", "<ses-not-normalized@amazonses.com>"}],
               fn _, _ -> true end
             )
  end

  test "an exact current Janitor reference does not parse an unrelated oversized thread history",
       ctx do
    outgoing(ctx.scope, "ses-current")
    long_history = Enum.map_join(1..30, " ", &"<old-#{&1}@example.com>")

    assert {:ok, %{inbox_id: "inbox"}} =
             Reference.delivery(ctx.scope, @sender, [
               {"In-Reply-To", "<ses-current@amazonses.com>"},
               {"References", long_history}
             ])
  end
end
