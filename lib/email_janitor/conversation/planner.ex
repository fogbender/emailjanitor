defmodule EmailJanitor.Conversation.Planner do
  @moduledoc "Transient conversation planning through the shared bounded model SDK."
  alias EmailJanitor.{Content, Inbox, Message, Preferences}
  alias EmailJanitor.Conversation.{Instructions, Plan, Reference}
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
    with {:ok, truncated} <- Keyword.fetch(opts, :search_truncated),
         true <- is_boolean(truncated),
         true <- byte_size(Content.read(request)) in 1..16_000,
         true <- String.valid?(Content.read(request)),
         true <- snapshot.inbox_id == inbox.id,
         true <- is_list(references) and length(references) <= 10,
         true <- Enum.all?(references, &match?(%Reference{}, &1)),
         true <- Enum.all?(references, &(&1.inbox_id == inbox.id)),
         tokens = Enum.map(references, & &1.token),
         true <- length(Enum.uniq(tokens)) == length(tokens),
         true <- is_list(messages) and length(messages) <= 5,
         true <- Enum.all?(messages, &known_message?(&1, references)),
         {:ok, messages} <- readable_messages(messages),
         instructions = %{
           all: Instructions.entries(snapshot.global),
           inbox: Instructions.entries(snapshot.local)
         },
         payload = %{
           "SELECTED_INBOX" => inbox.address,
           "EXISTING_PREFERENCES" => %{
             "all" => Enum.map(instructions.all, &instruction/1),
             "inbox" => Enum.map(instructions.inbox, &instruction/1)
           },
           "USER_MESSAGE" => Content.read(request),
           "PREVIOUS_EFFECTS" => Keyword.get(opts, :previous_effects),
           "SEARCH_RESULTS" => Enum.map(references, &reference/1),
           "SEARCH_TRUNCATED" => truncated,
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

      headers =
        Enum.flat_map(references, &[{:sender, &1.sender}, {:subject, &1.subject}]) ++
          Enum.flat_map(messages, fn message ->
            [
              {:sender, Content.new(header(message, "from"))},
              {:subject, Content.new(header(message, "subject"))}
            ]
          end)

      with {:ok, plan} <-
             Plan.parse(
               Content.read(object),
               tokens,
               bodies ++ headers,
               Map.new(instructions, fn {scope, rows} ->
                 {scope, rows |> Enum.filter(& &1.editable) |> Enum.map(& &1.id)}
               end)
             ),
           true <-
             not truncated or
               (plan.operation in [:search, :answer] and plan.preference_target == :none) do
        {:ok, %{plan | search_complete: not truncated}}
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

  defp instruction(entry),
    do: %{
      "reference" => entry.id,
      "text" => Content.read(entry.text),
      "editable" => entry.editable
    }

  defp readable_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case SDK.readable_body(message, 8_000) do
        {:ok, body} -> {:cont, {:ok, acc ++ [%{message | body: body}]}}
        _ -> {:halt, {:error, :unreadable_content}}
      end
    end)
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
