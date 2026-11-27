defmodule EmailJanitor.Conversation.Evidence do
  @moduledoc "Bounded, transient forwarded content, kept separate from the authenticated user's request."
  alias EmailJanitor.Content
  @keys ~w(sender subject body)

  def new(sender, subject, %Content{} = body) do
    value = %{"sender" => sender, "subject" => subject, "body" => Content.read(body)}

    if valid?(value),
      do: {:ok, Content.new(Jason.encode!(value))},
      else: {:error, :invalid_request_evidence}
  end

  def new(_, _, _), do: {:error, :invalid_request_evidence}
  def decode(nil), do: {:ok, nil}

  def decode(%Content{} = content) do
    with raw when byte_size(raw) <= 64_000 <- Content.read(content),
         {:ok, value} <- Jason.decode(raw),
         true <- valid?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_request_evidence}
    end
  rescue
    _ -> {:error, :invalid_request_evidence}
  end

  def decode(_), do: {:error, :invalid_request_evidence}
  def sources(nil), do: []

  def sources(value),
    do: [
      {:sender, Content.new(value["sender"])},
      {:subject, Content.new(value["subject"])},
      Content.new(value["body"])
    ]

  defp valid?(value) when is_map(value) and not is_struct(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@keys) and
      header?(value["sender"]) and header?(value["subject"]) and
      text?(value["body"], 8_000)
  end

  defp valid?(_), do: false
  defp header?(value), do: text?(value, 1_024) and not String.contains?(value, ["\r", "\n"])

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
        not String.contains?(value, <<0>>)
end
