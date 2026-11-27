defmodule EmailJanitor.Conversation.Lookup do
  @moduledoc "Refetches transient evidence from the host-selected Gmail inbox and resolves Janitor-owned actions."
  import Ecto.Query
  alias EmailJanitor.{Content, Message}
  alias EmailJanitor.Conversation.{Context, Reference}
  alias EmailJanitor.Store.Action

  def search(%Context{gmail: {gmail, options}} = ctx, %Content{} = query) do
    with :ok <- ctx.guard.(),
         {:ok, %{messages: pairs, truncated: truncated}} <-
           gmail.search(ctx.inbox.id, Content.read(query), options),
         true <- is_boolean(truncated),
         {:ok, refs, messages} <- load(ctx, pairs) do
      {:ok, refs, messages, truncated}
    else
      _ -> {:error, :lookup_unavailable}
    end
  rescue
    _ -> {:error, :lookup_unavailable}
  catch
    _, _ -> {:error, :lookup_unavailable}
  end

  def load(%Context{} = ctx, pairs) do
    if is_list(pairs) and length(pairs) <= 10 do
      Enum.reduce_while(pairs, {:ok, [], [], %{}}, fn pair, {:ok, refs, selected, threads} ->
        with {:ok, id, thread_id} <- pair(pair),
             {:ok, messages, threads} <- thread(ctx, thread_id, threads),
             %Message{} = message <-
               Enum.find(messages, &(&1.id == id and &1.thread_id == thread_id)),
             {:ok, ref} <-
               Reference.new(
                 ctx.inbox.id,
                 id,
                 thread_id,
                 metadata(message, "from", 512),
                 metadata(message, "subject", 1024),
                 action_id: action(ctx, id)
               ) do
          selected = if length(selected) < 5, do: selected ++ [message], else: selected
          {:cont, {:ok, refs ++ [ref], selected, threads}}
        else
          # A deleted reference is unavailable; never substitute a similar email.
          _ -> {:halt, {:error, :lookup_unavailable}}
        end
      end)
      |> case do
        {:ok, refs, messages, _} -> {:ok, refs, messages}
        error -> error
      end
    else
      {:error, :invalid_references}
    end
  rescue
    _ -> {:error, :lookup_unavailable}
  catch
    _, _ -> {:error, :lookup_unavailable}
  end

  defp pair(%{message_id: id, thread_id: thread_id}) do
    if EmailJanitor.Gmail.Parser.valid_id?(id) and EmailJanitor.Gmail.Parser.valid_id?(thread_id),
      do: {:ok, id, thread_id},
      else: {:error, :invalid_reference}
  end

  defp pair(%{"message_id" => id, "thread_id" => thread_id}),
    do: pair(%{message_id: id, thread_id: thread_id})

  defp pair(_), do: {:error, :invalid_reference}

  defp thread(%{gmail: {gmail, opts}} = ctx, thread_id, cache) do
    case Map.fetch(cache, thread_id) do
      {:ok, messages} ->
        {:ok, messages, cache}

      :error ->
        with :ok <- ctx.guard.(),
             {:ok, messages} <- gmail.thread(ctx.inbox.id, thread_id, opts),
             true <-
               is_list(messages) and length(messages) <= 200 and
                 Enum.all?(messages, &match?(%Message{thread_id: ^thread_id}, &1)) do
          {:ok, messages, Map.put(cache, thread_id, messages)}
        else
          _ -> {:error, :lookup_unavailable}
        end
    end
  end

  @doc false
  def confirmed_since(ctx, message_id, since) do
    ctx.scope.repo.one(
      from(a in Action,
        where:
          a.inbox_id == ^ctx.inbox.id and a.state in [:done, :restored] and
            ^message_id in a.applied_message_ids and a.dispatch_started_at >= ^since,
        order_by: [desc: a.inserted_at],
        limit: 1,
        select: a.id
      ),
      prefix: ctx.scope.prefix,
      log: false,
      telemetry_event: nil
    )
  end

  defp action(ctx, message_id) do
    ctx.scope.repo.one(
      from(a in Action,
        where:
          a.inbox_id == ^ctx.inbox.id and a.state in [:done, :restored] and
            ^message_id in a.applied_message_ids,
        order_by: [desc: a.inserted_at],
        limit: 1,
        select: a.id
      ),
      prefix: ctx.scope.prefix,
      log: false,
      telemetry_event: nil
    )
  end

  defp metadata(message, name, bytes) do
    value =
      case Message.header(message, name) do
        value when is_binary(value) -> value
        _ -> ""
      end

    cleaned = String.replace(value, ~r/[\x00-\x1F\x7F]/u, " ")
    prefix = binary_part(cleaned, 0, min(byte_size(cleaned), bytes))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      text when is_binary(text) -> text
      {:incomplete, text, _} -> text
      _ -> ""
    end
  end
end
