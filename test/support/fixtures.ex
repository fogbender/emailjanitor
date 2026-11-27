defmodule EmailJanitor.Fixtures do
  alias EmailJanitor.{Inbox, Message}

  def inbox(address \\ "owner@acme.com", relays \\ []) do
    {:ok, inbox} = Inbox.new("inbox-1", address, relays)
    inbox
  end

  def message(opts \\ []) do
    %Message{
      id: Keyword.get(opts, :id, "message-1"),
      thread_id: Keyword.get(opts, :thread_id, "thread-1"),
      labels: Keyword.get(opts, :labels, ["INBOX", "UNREAD", "IMPORTANT"]),
      headers:
        Keyword.get(opts, :headers, [
          {"From", Keyword.get(opts, :from, "Sales <sales@vendor.com>")}
        ])
    }
    |> Message.with_body(
      Keyword.get(opts, :body, "Synthetic unsolicited development services pitch.")
    )
  end
end

defmodule EmailJanitor.TestClassifier do
  @behaviour EmailJanitor.Classifier
  def classify(messages, instructions, opts) do
    if notify = opts[:notify], do: send(notify, {:classified, length(messages), instructions})

    case opts[:mode] do
      :raise ->
        raise "PRIVATE_BODY_SENTINEL"

      :raw_error ->
        {:error, "PRIVATE_BODY_SENTINEL"}

      :throw ->
        throw("PRIVATE_BODY_SENTINEL")

      _ ->
        {:ok,
         Keyword.get(opts, :result, %{
           "action" => "done",
           "confidence" => "high",
           "category" => "cold_outreach"
         })}
    end
  end
end

defmodule EmailJanitor.TestGmail do
  @behaviour EmailJanitor.Gmail
  def history_id(_inbox, _opts), do: {:ok, "100"}
  def thread(_inbox, _thread, opts), do: Agent.get(opts[:state], &{:ok, &1.messages})

  def contacted(_inbox, keys, opts) do
    Agent.get(opts[:state], fn state ->
      {:ok, MapSet.intersection(MapSet.new(keys), MapSet.new(state.contacted))}
    end)
  end

  def remove_inbox(_inbox, ids, opts) do
    # Execute the inspection in the caller, so SQL sandbox ownership is preserved.
    if before = opts[:before], do: before.()

    Agent.update(opts[:state], fn state ->
      messages =
        Enum.map(state.messages, fn m ->
          if m.id in ids, do: %{m | labels: List.delete(m.labels, "INBOX")}, else: m
        end)

      %{state | messages: messages, calls: state.calls ++ [ids]}
    end)

    case opts[:mode] do
      :timeout_after_apply -> {:error, :timeout}
      :raise_after_apply -> raise "PRIVATE_BODY_SENTINEL"
      _ -> :ok
    end
  end
end
