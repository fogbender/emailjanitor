defmodule EmailJanitor.Mail.Feedback do
  @moduledoc "Authenticated email feedback. SMTP content supplies routing hints only; commands come from a fresh own-Sent copy."
  import Ecto.Query
  alias EmailJanitor.{Content, Inbox, Store}
  alias EmailJanitor.Mail.{Incoming, Message, Outbox, RFCMessageID}

  alias EmailJanitor.Mail.Feedback.{
    Auth,
    Binding,
    Config,
    Context,
    Envelope,
    Ledger,
    Record,
    ReplyParser,
    Route
  }

  def install(scope) do
    with result when result in [:ok, :already_up] <- EmailJanitor.Mail.Store.install(scope),
         result when result in [:ok, :already_up] <-
           Ecto.Migrator.up(scope.repo, 13, EmailJanitor.Mail.Feedback.Migration,
             prefix: scope.prefix,
             log: false
           ),
         do: :ok
  end

  @doc "Use as the Spool.process handler. Once metadata is durable, even indexing retries return success so raw S3 input is purged."
  def accept(%Config{} = config, %Incoming{} = incoming, %Content{} = raw) do
    safe(
      fn ->
        with {:ok, envelope} <- Envelope.new(incoming, raw, config.mail.sender),
             true <- DateTime.compare(envelope.expires_at, DateTime.utc_now()) == :gt do
          case config.route.(envelope) do
            {:ok, %Route{} = route} -> accept_known(config, envelope, route)
            :unknown -> accept_signup(config, envelope)
            _ -> :rejected
          end
        else
          :ignored -> :ignored
          false -> :ignored
          _ -> :rejected
        end
      end,
      :rejected
    )
  end

  defp accept_known(config, envelope, route) do
    with true <- Config.opaque_key?(route.key),
         {:ok, id} <- RFCMessageID.request_id(route.inbox_id, envelope.rfc_message_id),
         now = DateTime.utc_now(),
         {:ok, _} <-
           Ledger.insert(config.transport_scope, %Record{
             id: id,
             kind: :feedback,
             source_ses_id: envelope.ses_id,
             sender_address: envelope.from,
             sender_inbox_id: route.inbox_id,
             rfc_message_id: envelope.rfc_message_id,
             route_key: route.key,
             received_at: envelope.received_at,
             expires_at: envelope.expires_at,
             inserted_at: now,
             updated_at: now
           }) do
      {:ok, id}
    else
      _ -> :rejected
    end
  end

  defp accept_signup(%Config{signup_url: nil}, _), do: :ignored
  defp accept_signup(_, %{signup_allowed: false}), do: :ignored

  defp accept_signup(config, envelope) do
    scope = config.transport_scope

    recipient_id =
      "feedback-recipient-" <> Base.encode16(:crypto.hash(:sha256, envelope.from), case: :lower)

    day = Date.to_iso8601(DateTime.to_date(envelope.received_at))
    {:ok, id} = RFCMessageID.request_id(recipient_id, "signup-" <> day <> "@emailjanitor.invalid")

    case scope.repo.transaction(fn ->
           scope.repo.one!(
             from(m in Store.Mailbox,
               where: m.id == ^config.transport_inbox.id,
               lock: "FOR UPDATE"
             ),
             prefix: scope.prefix
           )

           existing = Ledger.get(scope, id)

           if existing do
             existing
           else
             start =
               DateTime.new!(DateTime.to_date(envelope.received_at), ~T[00:00:00], "Etc/UTC")

             count =
               scope.repo.aggregate(
                 from(r in Record,
                   where:
                     r.kind == :signup and r.received_at >= ^start and
                       r.received_at < ^DateTime.add(start, 86400)
                 ),
                 :count,
                 prefix: scope.prefix
               )

             if count >= 100, do: scope.repo.rollback(:signup_rate_limited)
             {:ok, inbox} = Inbox.new(recipient_id, envelope.from)
             {:ok, _} = Store.add_inbox(scope, inbox)
             now = DateTime.utc_now()

             {:ok, row} =
               Ledger.insert(scope, %Record{
                 id: id,
                 kind: :signup,
                 source_ses_id: envelope.ses_id,
                 sender_address: envelope.from,
                 sender_inbox_id: recipient_id,
                 rfc_message_id: envelope.rfc_message_id,
                 received_at: envelope.received_at,
                 expires_at: envelope.expires_at,
                 inserted_at: now,
                 updated_at: now
               })

             row
           end
         end) do
      {:ok, _} -> {:ok, id}
      _ -> :ignored
    end
  end

  @doc "One bounded due receipt. Host supervision bounds concurrent callers; no raw SMTP body is needed."
  def tick(%Config{} = config) do
    safe(fn ->
      case Ledger.due(config.transport_scope, DateTime.utc_now()) do
        nil -> {:ok, :idle}
        row -> process(config, row.id)
      end
    end)
  end

  def process(%Config{} = config, id) do
    safe(fn ->
      with false <- config.transport_scope.repo.in_transaction?(),
           {:ok, _} <- Ecto.UUID.cast(id),
           {:ok, row, _previous} <- Ledger.claim(config.transport_scope, id, DateTime.utc_now()) do
        case row.kind do
          :signup -> signup(config, row)
          :feedback -> feedback(config, row)
        end
      else
        _ -> {:error, :feedback_busy}
      end
    end)
  end

  defp feedback(config, row) do
    with {:ok, %Binding{} = binding} <- config.resolve.(row.route_key),
         true <-
           binding.inbox.id == row.sender_inbox_id and binding.inbox.address == row.sender_address,
         :ok <- binding.guard.() do
      cond do
        not is_nil(row.outcome) ->
          reply_only(config, row, binding)

        DateTime.compare(DateTime.utc_now(), row.expires_at) != :lt ->
          expired(config, row, binding)

        true ->
          authenticate(config, row, binding)
      end
    else
      _ -> finish(config, row, :rejected, :rejected)
    end
  end

  defp authenticate(config, row, binding) do
    {gmail, opts} = binding.gmail

    case gmail.feedback_sent(binding.inbox.id, row.rfc_message_id, opts) do
      {:ok, sent} ->
        with :ok <-
               Auth.verify(
                 sent,
                 binding.inbox,
                 row.rfc_message_id,
                 config.mail.sender,
                 row.received_at
               ),
             {:ok, %Context{} = context} <- binding.route_verified.(sent),
             :ok <- valid_context(binding, context),
             {:ok, request_id} <- RFCMessageID.request_id(context.inbox.id, row.rfc_message_id),
             true <-
               is_nil(row.context_key) or
                 (row.context_key == context.key and row.request_id == request_id),
             {:ok, row} <-
               Ledger.update(config.transport_scope, row, %{
                 authenticated_at: row.authenticated_at || DateTime.utc_now(),
                 context_key: context.key,
                 command_inbox_id: context.inbox.id,
                 conversation_id: context.conversation_id,
                 request_id: request_id,
                 original_subject: safe_subject(sent)
               }),
             {:ok, parsed} <- ReplyParser.parse(config.parser_executable, sent) do
          case parsed.status do
            :clarify ->
              prepare_reply(config, row, binding, context, :clarify_ambiguous, clarification())

            :parsed ->
              run_workflow(config, row, binding, context, parsed)
          end
        else
          {:error, :reply_context_unavailable} -> retry(config, row, :waiting_sent)
          {:error, :unverified_reply_reference} -> retry(config, row, :waiting_sent)
          _ -> finish(config, row, :rejected, :rejected)
        end

      {:error, reason} when reason in [:sent_not_indexed, :gmail_unavailable, :rate_limited] ->
        retry(config, row, :waiting_sent)

      _ ->
        finish(config, row, :rejected, :rejected)
    end
  end

  defp run_workflow(config, row, binding, context, parsed) do
    if parsed.evidence_omitted do
      prepare_reply(config, row, binding, context, :clarify_ambiguous, clarification())
    else
      with :ok <- context.guard.(),
           {:ok, %Content{} = reply} <-
             context.respond.(row.request_id, parsed.authored, parsed.evidence) do
        prepare_reply(config, row, binding, context, :processed, reply)
      else
        _ -> retry(config, row, :workflow_retry)
      end
    end
  end

  defp expired(config, %{authenticated_at: nil} = row, _),
    do: finish(config, row, :expired, :expired)

  defp expired(config, row, binding) do
    with {:ok, %Context{} = context} <- binding.restore_context.(row.context_key),
         :ok <- valid_context(binding, context),
         true <-
           context.inbox.id == row.command_inbox_id and
             context.conversation_id == row.conversation_id do
      prepare_reply(config, row, binding, context, :answer_unavailable, nil)
    else
      _ -> finish(config, row, :expired, :expired)
    end
  end

  defp reply_only(config, row, binding) do
    with {:ok, %Context{} = context} <- binding.restore_context.(row.context_key),
         :ok <- valid_context(binding, context),
         true <-
           context.inbox.id == row.command_inbox_id and
             context.conversation_id == row.conversation_id do
      send_reply(config, row, binding, context, nil)
    else
      _ -> finish(config, row, :rejected, :rejected)
    end
  end

  defp prepare_reply(config, row, binding, context, outcome, live_reply) do
    with {:ok, row} <- Ledger.update(config.transport_scope, row, %{outcome: outcome}) do
      send_reply(config, row, binding, context, live_reply)
    end
  end

  defp send_reply(config, row, binding, context, live_reply) do
    authorize = fn inbox_id ->
      with true <- inbox_id == binding.inbox.id,
           :ok <- binding.guard.(),
           do: {:ok, binding.inbox},
           else: (_ -> {:error, :feedback_connection_changed})
    end

    render = fn _ ->
      reply = live_reply || render_reply(row, context)
      Message.new("Email Janitor", reply)
    end

    with {:ok, outgoing} <-
           Outbox.enqueue(binding.scope, binding.inbox.id, :assistant, [row.id], row.id) do
      case Outbox.deliver(binding.scope, outgoing.id, config.mail, authorize, render) do
        :ok -> finish(config, row, :completed, row.outcome)
        {:error, :unresolved_delivery} -> finish(config, row, :unresolved, row.outcome)
        _ -> retry(config, row, :reply_pending)
      end
    else
      _ -> retry(config, row, :reply_pending)
    end
  end

  defp render_reply(%{outcome: reason}, _)
       when reason in [:clarify_ambiguous, :clarify_unsupported],
       do: clarification()

  defp render_reply(row, context) do
    case context.render.(row.request_id) do
      {:ok, %Content{} = reply} ->
        reply

      _ ->
        Content.new(
          "I could not recover a retained answer for that request. Reply with what you need next; no email bodies or conversational answers are stored."
        )
    end
  end

  defp signup(config, row) do
    if DateTime.compare(DateTime.utc_now(), row.expires_at) != :lt do
      finish(config, row, :expired, :expired)
    else
      {:ok, inbox} = Inbox.new(row.sender_inbox_id, row.sender_address)

      authorize = fn id ->
        if id == inbox.id, do: {:ok, inbox}, else: {:error, :wrong_recipient}
      end

      render = fn _ ->
        Message.new(
          "Email Janitor",
          Content.new(
            "Connect your Google inbox to Email Janitor at " <>
              config.signup_url <> ". Then send your request again."
          )
        )
      end

      with {:ok, outgoing} <-
             Outbox.enqueue(config.transport_scope, inbox.id, :assistant, [row.id], row.id) do
        case Outbox.deliver(config.transport_scope, outgoing.id, config.mail, authorize, render) do
          :ok -> finish(config, row, :completed, :processed)
          {:error, :unresolved_delivery} -> finish(config, row, :unresolved, :processed)
          _ -> retry(config, row, :reply_pending)
        end
      else
        _ -> retry(config, row, :reply_pending)
      end
    end
  end

  defp valid_context(binding, %Context{} = context) do
    with true <- Config.opaque_key?(context.key),
         true <-
           binding.scope.repo == context.scope.repo and
             binding.scope.prefix == context.scope.prefix,
         {:ok, _} <- Ecto.UUID.cast(context.conversation_id),
         true <-
           is_function(context.guard, 0) and is_function(context.respond, 3) and
             is_function(context.render, 1),
         :ok <- context.guard.(),
         do: :ok,
         else: (_ -> {:error, :invalid_feedback_context})
  end

  defp safe_subject(sent) do
    case EmailJanitor.Message.header(sent, "subject") do
      subject when is_binary(subject) and byte_size(subject) in 1..256 ->
        if String.valid?(subject) and not String.contains?(subject, ["\r", "\n", <<0>>]),
          do: subject,
          else: "Email Janitor"

      _ ->
        "Email Janitor"
    end
  end

  defp clarification,
    do:
      Content.new(
        "I could not safely separate your note from the quoted or forwarded email. Please send a new message with the sender or subject and what you want me to do."
      )

  defp retry(config, row, state) do
    with {:ok, _} <- Ledger.retry(config.transport_scope, row, state, DateTime.utc_now()),
         do: {:ok, :deferred}
  end

  defp finish(config, row, state, outcome) do
    with {:ok, _} <-
           Ledger.update(config.transport_scope, row, %{
             state: state,
             outcome: outcome,
             lease_until: nil,
             next_attempt_at: nil
           }),
         do: {:ok, state}
  end

  defp safe(fun, fallback \\ {:error, :feedback_unavailable}) do
    try do
      fun.()
    rescue
      _ -> fallback
    catch
      _, _ -> fallback
    end
  end
end
