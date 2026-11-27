defmodule EmailJanitor.Mail.Feedback.ReplyParser do
  @moduledoc "Bounded one-shot IPC to maintained reply/forward parsers. Content never appears in process arguments or logs."
  alias EmailJanitor.{Content, Message}

  def parse(executable, %Message{feedback_format: :plain, body: %Content{} = body} = message) do
    with true <- is_binary(executable) and Path.type(executable) == :absolute,
         subject when is_binary(subject) <- Message.header(message, "subject") || "",
         true <- byte_size(subject) <= 1024,
         raw = Content.read(body),
         true <- is_binary(raw) and byte_size(raw) <= 1_000_000,
         frame =
           Jason.encode!(%{
             body: raw,
             subject: subject,
             reply_expected:
               not is_nil(Message.header(message, "in-reply-to")) or
                 not is_nil(Message.header(message, "references"))
           }) <> "\n",
         {:ok, value} <- command(executable, frame),
         {:ok, decoded} <- decode(value) do
      {:ok, decoded}
    else
      _ -> {:error, :reply_parser_unavailable}
    end
  rescue
    _ -> {:error, :reply_parser_unavailable}
  catch
    _, _ -> {:error, :reply_parser_unavailable}
  end

  def parse(_, %Message{}), do: {:ok, %{status: :clarify, reason: :unsupported_format}}

  defp command(executable, frame) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide
      ])

    try do
      true = Port.command(port, frame)
      receive_output(port, <<>>, System.monotonic_time(:millisecond) + 5_000)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp receive_output(port, buffer, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(buffer) + byte_size(data) <= 96_000 ->
        receive_output(port, buffer <> data, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, buffer}

      {^port, _} ->
        {:error, :reply_parser_unavailable}
    after
      timeout -> {:error, :reply_parser_unavailable}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"status" => "clarify", "reason" => reason} = value} when map_size(value) == 2 ->
        if reason in ~w(unreadable forward_ambiguous reply_ambiguous),
          do: {:ok, %{status: :clarify, reason: :ambiguous_content}},
          else: {:error, :reply_parser_unavailable}

      {:ok,
       %{
         "status" => "parsed",
         "kind" => kind,
         "authored" => authored,
         "evidence" => evidence,
         "evidence_omitted" => omitted
       } = value}
      when map_size(value) == 5 ->
        with true <- kind in ~w(direct reply forward),
             true <-
               is_binary(authored) and String.valid?(authored) and
                 byte_size(authored) in 1..16_000,
             true <- is_boolean(omitted),
             {:ok, evidence} <- evidence(evidence),
             true <- not omitted or is_nil(evidence) do
          {:ok,
           %{
             status: :parsed,
             kind: kind,
             authored: Content.new(authored),
             evidence: evidence,
             evidence_omitted: omitted
           }}
        else
          _ -> {:error, :reply_parser_unavailable}
        end

      _ ->
        {:error, :reply_parser_unavailable}
    end
  end

  defp evidence(nil), do: {:ok, nil}

  defp evidence(%{"sender" => sender, "subject" => subject, "body" => body} = value)
       when map_size(value) == 3 do
    if Enum.all?([sender, subject, body], &(is_binary(&1) and String.valid?(&1))) and
         byte_size(sender) <= 1024 and byte_size(subject) <= 1024 and byte_size(body) in 1..8000,
       do:
         {:ok,
          %{sender: Content.new(sender), subject: Content.new(subject), body: Content.new(body)}},
       else: {:error, :reply_parser_unavailable}
  end

  defp evidence(_), do: {:error, :reply_parser_unavailable}
end
