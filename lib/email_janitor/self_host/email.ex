defmodule EmailJanitor.SelfHost.Email do
  @moduledoc "Single-owner adapters for authenticated shared email feedback. SMTP hints never choose authority."
  alias EmailJanitor.{Content, Conversation, Digest, Preferences, SelfHost}
  alias EmailJanitor.Conversation.{Ledger, Outcome, Receipt}
  alias EmailJanitor.Gmail.Parser
  alias EmailJanitor.Mail.Feedback
  alias EmailJanitor.Mail.Feedback.{Binding, Context, Envelope, Route}
  alias EmailJanitor.Mail.Feedback.Config, as: FeedbackConfig
  alias EmailJanitor.Mail.Feedback.Reference, as: DeliveryReference
  alias EmailJanitor.SelfHost.{Adapters, Owner, Runtime, Store, Transport}

  def config(config) do
    with {:ok, mail} <- Adapters.mail(config),
         {:ok, transport} <- Transport.inbox(config) do
      FeedbackConfig.new(
        transport_scope: SelfHost.scope(),
        transport_inbox: transport,
        mail: mail,
        parser_executable: config.reply_parser_executable,
        route: &route/1,
        resolve: fn key -> resolve(config, key) end
      )
    end
  end

  def route(%Envelope{from: address}) do
    with {:ok, refs} <- Store.refs() do
      matches =
        for ref <- refs,
            {:ok, _, %{address: ^address} = inbox} <- [Store.fetch_binding(ref)],
            do: {ref, inbox}

      case matches do
        [{{id, epoch}, inbox}] ->
          {:ok, %Route{key: encode(%{"id" => id, "epoch" => epoch}), inbox_id: inbox.id}}

        [] ->
          :unknown

        _ ->
          {:error, :ambiguous_feedback_route}
      end
    end
  rescue
    _ -> {:error, :feedback_route_unavailable}
  end

  def resolve(config, key) do
    with {:ok, %{"id" => id, "epoch" => epoch} = value} <- decode(key),
         true <- Enum.sort(Map.keys(value)) == ~w(epoch id),
         true <- valid_ref?(id, epoch),
         ref = {id, epoch},
         {:ok, _, inbox} <- Store.fetch_binding(ref),
         {:ok, gmail} <- Adapters.gmail(ref) do
      {:ok,
       %Binding{
         scope: SelfHost.scope(),
         inbox: inbox,
         gmail: gmail,
         guard: fn -> Store.guard(ref, inbox) end,
         route_verified: fn sent -> verified(config, ref, sent) end,
         restore_context: fn context_key -> restore_context(ref, context_key) end
       }}
    else
      _ -> {:error, :feedback_connection_changed}
    end
  rescue
    _ -> {:error, :feedback_connection_changed}
  end

  defp verified(config, sender_ref, sent) do
    with {:ok, mail} <- Adapters.mail(config),
         {:ok, delivery} <-
           DeliveryReference.delivery(
             SelfHost.scope(),
             mail.sender,
             sent.headers,
             &Store.recipient?/2
           ),
         {:ok, target_id, conversation} <- target(sender_ref, sent.thread_id, delivery),
         {:ok, target_ref} <- current_ref(target_id) do
      build(sender_ref, target_ref, conversation, delivery != :none)
    else
      {:error, reason} when reason in [:unverified_reply_reference, :ambiguous_reply_reference] ->
        with {:ok, id, conversation} <- target(sender_ref, sent.thread_id, :none),
             {:ok, target_ref} <- current_ref(id),
             {:ok, context} <- build(sender_ref, target_ref, conversation),
             do: {:clarify, context}

      _ ->
        {:error, :reply_context_unavailable}
    end
  rescue
    _ -> {:error, :reply_context_unavailable}
  end

  defp target({sender, _}, thread, :none) do
    if Parser.valid_id?(thread),
      do: {:ok, sender, conversation_id(sender, thread)},
      else: {:error, :invalid_feedback_thread}
  end

  defp target(_, _, %{kind: :digest, inbox_id: id, reference_ids: [snapshot_id]}) do
    case Digest.get(SelfHost.scope(), snapshot_id) do
      %{id: ^snapshot_id, inbox_id: ^id} -> {:ok, id, snapshot_id}
      _ -> {:error, :unverified_reply_reference}
    end
  end

  defp target(_, _, %{kind: :assistant, inbox_id: recipient, reference_ids: [receipt_id]}) do
    case Feedback.Ledger.get(SelfHost.scope(), receipt_id) do
      %{
        kind: :feedback,
        sender_inbox_id: ^recipient,
        command_inbox_id: id,
        conversation_id: conversation,
        authenticated_at: %DateTime{},
        outcome: outcome
      }
      when not is_nil(outcome) ->
        {:ok, id, conversation}

      _ ->
        {:error, :unverified_reply_reference}
    end
  end

  defp target(_, _, _), do: {:error, :ambiguous_reply_reference}

  defp restore_context({sender_id, sender_epoch} = sender_ref, key) do
    with {:ok,
          %{
            "sender" => ^sender_id,
            "sender_epoch" => ^sender_epoch,
            "command" => id,
            "command_epoch" => epoch,
            "conversation" => conversation,
            "verified_reference" => verified_reference
          } = value} <- decode(key),
         true <-
           Enum.sort(Map.keys(value)) ==
             ~w(command command_epoch conversation sender sender_epoch verified_reference),
         true <- is_boolean(verified_reference),
         true <- valid_ref?(id, epoch),
         {:ok, conversation} <- Ecto.UUID.cast(conversation) do
      build(sender_ref, {id, epoch}, conversation, verified_reference)
    else
      _ -> {:error, :feedback_connection_changed}
    end
  end

  defp build(sender_ref, target_ref, conversation, verified_reference \\ false)

  defp build(
         {sender_id, sender_epoch} = sender_ref,
         {id, epoch} = target_ref,
         conversation,
         verified_reference
       ) do
    scope = SelfHost.scope()

    with %Owner{subject: owner} <- scope.repo.get(Owner, 1, prefix: scope.prefix, log: false),
         {:ok, _, sender_inbox} <- Store.fetch_binding(sender_ref),
         {:ok, %{state: :active}, inbox} <- Store.fetch_binding(target_ref),
         {:ok, conversation} <- Ecto.UUID.cast(conversation),
         {:ok, engine} <- Runtime.context(owner, id, conversation) do
      guard = fn ->
        with :ok <- Store.guard(sender_ref, sender_inbox), do: engine.guard.()
      end

      key =
        encode(%{
          "sender" => sender_id,
          "sender_epoch" => sender_epoch,
          "command" => id,
          "command_epoch" => epoch,
          "conversation" => conversation,
          "verified_reference" => verified_reference
        })

      {:ok,
       %Context{
         key: key,
         scope: scope,
         inbox: inbox,
         conversation_id: conversation,
         verified_reference: verified_reference,
         guard: guard,
         respond: fn request, authored, evidence ->
           with :ok <- guard.(),
                do:
                  Conversation.respond(%{engine | request_evidence: evidence}, request, authored)
         end,
         render: fn request -> render(owner, id, conversation, request) end
       }}
    else
      _ -> {:error, :reply_context_unavailable}
    end
  end

  def render(owner, id, conversation, request) do
    if SelfHost.owner?(owner),
      do: render_completed(id, conversation, request),
      else: {:error, :unauthorized}
  end

  defp render_completed(id, conversation, request) do
    with {:ok, conversation} <- Ecto.UUID.cast(conversation),
         {:ok, request} <- Ecto.UUID.cast(request),
         %Receipt{completed: true} = receipt <-
           Ledger.get(SelfHost.scope(), id, conversation, request),
         {:ok, snapshot} <- Preferences.snapshot(SelfHost.scope(), id) do
      {:ok, Outcome.render(receipt, snapshot)}
    else
      _ ->
        {:ok,
         Content.new(
           "I could not recover that conversational answer. Please reply again with the sender or subject and what you need."
         )}
    end
  rescue
    _ -> {:error, :feedback_answer_unavailable}
  end

  defp current_ref(id) do
    with {:ok, refs} <- Store.refs(),
         ref when not is_nil(ref) <- Enum.find(refs, fn {box, _} -> box == id end),
         do: {:ok, ref},
         else: (_ -> {:error, :feedback_connection_changed})
  end

  defp valid_ref?(id, epoch),
    do:
      is_binary(id) and byte_size(id) in 1..200 and is_integer(epoch) and
        epoch in 1..9_223_372_036_854_775_807

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp decode(value) when is_binary(value) and byte_size(value) in 1..1024 do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(raw),
         do: {:ok, map},
         else: (_ -> {:error, :invalid_feedback_key})
  end

  defp decode(_), do: {:error, :invalid_feedback_key}

  defp conversation_id(sender, thread) do
    <<a::32, b::16, _::4, c::12, _::2, d::62, _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary({:selfhost_email_thread, sender, thread}))

    {:ok, uuid} = Ecto.UUID.load(<<a::32, b::16, 5::4, c::12, 2::2, d::62>>)
    uuid
  end
end
