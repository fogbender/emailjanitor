defmodule EmailJanitor.SelfHost.Runtime do
  @moduledoc "Build trusted shared-engine capabilities from the fixed host and its connected Google identity."
  alias EmailJanitor.{Content, Conversation.Context, Digest, SelfHost}
  alias EmailJanitor.Gmail.Ingestion
  alias EmailJanitor.SelfHost.{ActivityPolicy, Adapters, Authority, Binding, Store}

  def ready?(config) do
    worker = EmailJanitor.Worker.Config

    modules = [
      {EmailJanitor.Worker.Server, :start_link, 1},
      {EmailJanitor.Conversation, :respond, 3},
      {EmailJanitor.Restore, :apply, 7},
      {Digest, :withdraw_pending, 3},
      {EmailJanitor.Mail.Feedback, :accept, 3},
      {EmailJanitor.Mail.Feedback, :tick, 1}
    ]

    runtime_configured?(config) and Code.ensure_loaded?(worker) and
      Map.has_key?(struct(worker), :policy_for_messages) and
      Enum.all?(modules, fn {module, function, arity} ->
        Code.ensure_loaded?(module) and function_exported?(module, function, arity)
      end)
  end

  defp runtime_configured?(config) do
    with true <- not is_nil(config.google_oauth),
         path when is_binary(path) <- config.reply_parser_executable,
         {:ok, %{type: :regular, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) != 0,
         {:ok, _} <- Adapters.mail(config),
         {:ok, _} <- Adapters.pubsub(config) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def respond(owner, inbox, conversation, request, %Content{} = message) do
    module = EmailJanitor.Conversation

    with true <- Code.ensure_loaded?(module) and function_exported?(module, :respond, 3),
         {:ok, context} <- context(owner, inbox, conversation) do
      module.respond(context, request, message)
    else
      _ -> {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  end

  def context(owner, id, conversation) do
    config = SelfHost.config()

    with true <- SelfHost.owner?(owner),
         {:ok, conversation} <- Ecto.UUID.cast(conversation),
         {:ok, ref} <- ref(id),
         {:ok, %Binding{state: :active}, inbox} <- Store.fetch_binding(ref),
         {:ok, gmail} <- Adapters.gmail(ref),
         {:ok, model} <- Adapters.model(config),
         {:ok, mail} <- Adapters.mail(config) do
      guard = fn -> Store.guard(ref, inbox) end

      {:ok,
       %Context{
         scope: SelfHost.scope(),
         inbox: inbox,
         conversation_id: conversation,
         gmail: gmail,
         model: [config: model],
         guard: guard,
         policy: ActivityPolicy.settlement(ref, inbox),
         execution_options: [
           on_plan_admitted: fn request, operation, references ->
             Authority.record(ref, owner, conversation, request, operation, references)
           end,
           policy_for_references: fn references ->
             policy(ActivityPolicy.for_references(ref, inbox, references))
           end,
           self_mail: fn headers -> Adapters.self_mail(mail.sender).(inbox, headers) end,
           on_restored: fn _action, ids -> withdraw(inbox.id, ids) end
         ]
       }}
    else
      _ -> {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  end

  def worker_config(ref) do
    module = EmailJanitor.Worker.Config
    config = SelfHost.config()

    with true <- Code.ensure_loaded?(module),
         true <- Map.has_key?(struct(module), :policy_for_messages),
         {:ok, binding, inbox} <- Store.fetch_binding(ref),
         ref = {binding.id, binding.epoch},
         {:ok, gmail} <- Adapters.gmail(ref),
         {:ok, model} <- Adapters.model(config),
         {:ok, mail} <- Adapters.mail(config),
         {:ok, lifecycle} <- lifecycle(binding) do
      guard = fn -> Store.guard(ref, inbox) end

      module.new(SelfHost.scope(), inbox,
        gmail: gmail,
        classifier: {EmailJanitor.Models.SDK, [config: model]},
        topic: config.pubsub["JANITOR_GOOGLE_TOPIC"],
        preferences: fn -> Adapters.preferences(inbox.id) end,
        authorize: guard,
        policy: ActivityPolicy.settlement(ref, inbox),
        policy_for_messages: fn messages ->
          policy(ActivityPolicy.for_messages(ref, inbox, messages))
        end,
        lifecycle: lifecycle,
        on_baseline: fn checkpoint ->
          if checkpoint.inbox_id == inbox.id,
            do: Store.activate(ref),
            else: {:error, :connection_changed}
        end,
        allow_recheck: fn _candidate -> guard.() end,
        allow_manual_recheck: fn authority, ids ->
          with :ok <- guard.(), do: Authority.allow(ref, authority, ids)
        end,
        self_mail: fn headers -> Adapters.self_mail(mail.sender).(inbox, headers) end
      )
    else
      _ -> {:error, :worker_unavailable}
    end
  rescue
    _ -> {:error, :worker_unavailable}
  end

  defp ref(id) do
    with {:ok, refs} <- Store.refs(),
         ref when not is_nil(ref) <- Enum.find(refs, fn {inbox, _} -> inbox == id end) do
      {:ok, ref}
    else
      _ -> {:error, :inbox_unavailable}
    end
  end

  defp lifecycle(%Binding{reset_baseline: true, id: id}) do
    case Ingestion.checkpoint(SelfHost.scope(), id) do
      {:ok, checkpoint} -> {:ok, {:reconnect, checkpoint.generation}}
      {:error, :not_initialized} -> {:ok, :resume}
      _ -> {:error, :worker_unavailable}
    end
  end

  defp lifecycle(_), do: {:ok, :resume}

  defp policy({:ok, policy}), do: policy
  defp policy(_), do: {:error, :policy_unavailable}

  defp withdraw(inbox, ids) do
    # Optional during source integration; a complete host release requires this
    # reviewed core API before enabling restoration/digest delivery.
    module = Digest

    if function_exported?(module, :withdraw_pending, 3),
      do: module.withdraw_pending(SelfHost.scope(), inbox, ids),
      else: {:error, :digest_unavailable}
  end
end
