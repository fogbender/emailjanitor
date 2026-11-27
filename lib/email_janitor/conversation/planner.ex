defmodule EmailJanitor.Conversation.Planner do
  @moduledoc "Transient conversation planning through the shared bounded model SDK."
  alias EmailJanitor.{Content, Inbox, Message, Preferences}
  alias EmailJanitor.Conversation.{Plan, Reference}
  alias EmailJanitor.Models.SDK
  @external_resource Path.expand("../../../priv/prompts/conversation.txt", __DIR__)
  @prompt File.read!(@external_resource)

  def plan(
        %Inbox{} = inbox,
        %Preferences.Snapshot{} = snapshot,
        %Content{} = request,
        references,
        messages,
        opts
      ) do
    with true <- byte_size(Content.read(request)) in 1..16_000,
         true <- String.valid?(Content.read(request)),
         true <- snapshot.inbox_id == inbox.id,
         true <- is_list(references) and length(references) <= 10,
         true <- Enum.all?(references, &match?(%Reference{}, &1)),
         true <- Enum.all?(references, &(&1.inbox_id == inbox.id)),
         tokens = Enum.map(references, & &1.token),
         true <- length(Enum.uniq(tokens)) == length(tokens),
         true <- is_list(messages) and length(messages) <= 5,
         true <- Enum.all?(messages, &known_message?(&1, references)),
         payload = %{
           "SELECTED_INBOX" => inbox.address,
           "EXISTING_PREFERENCES" => %{
             "all" => Content.read(snapshot.global),
             "inbox" => Content.read(snapshot.local)
           },
           "USER_MESSAGE" => Content.read(request),
           "SEARCH_RESULTS" => Enum.map(references, &reference/1),
           "SEARCH_TRUNCATED" => Keyword.get(opts, :search_truncated, false),
           "UNTRUSTED_EMAILS" => Enum.map(messages, &message(&1, references))
         },
         {:ok, object} <-
           SDK.object(
             Content.new(@prompt),
             Content.new(Jason.encode!(payload)),
             Plan.schema(),
             opts
           ) do
      bodies = messages |> Enum.map(& &1.body) |> Enum.filter(&match?(%Content{}, &1))

      with {:ok, plan} <- Plan.parse(Content.read(object), tokens, bodies),
           true <-
             not Keyword.get(opts, :search_truncated, false) or
               (plan.operation in [:search, :answer] and plan.preference_target == :none) do
        {:ok, plan}
      else
        _ -> {:error, :conversation_unavailable}
      end
    else
      _ -> {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp known_message?(%Message{} = message, references),
    do:
      Enum.any?(references, &(&1.message_id == message.id and &1.thread_id == message.thread_id))

  defp known_message?(_, _), do: false

  defp reference(%Reference{} = ref) do
    %{
      "reference" => ref.token,
      "sender" => Content.read(ref.sender),
      "subject" => Content.read(ref.subject),
      "janitor_action" => not is_nil(ref.action_id)
    }
  end

  defp message(%Message{} = message, references) do
    ref = Enum.find(references, &(&1.message_id == message.id))

    %{
      "reference" => ref.token,
      "labels" =>
        Enum.filter(message.labels, &(&1 in ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM"])),
      "sender" => header(message, "from"),
      "subject" => header(message, "subject"),
      "body" => if(message.body, do: bounded(Content.read(message.body), 8_000), else: "")
    }
  end

  defp header(message, name) do
    case Message.header(message, name) do
      value when is_binary(value) -> bounded(value, 1024)
      _ -> ""
    end
  end

  defp bounded(value, bytes) do
    prefix = binary_part(value, 0, min(byte_size(value), bytes))

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _} -> valid
      _ -> throw(:invalid_text)
    end
  end
end
