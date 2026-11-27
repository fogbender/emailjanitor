defmodule EmailJanitor.Digest.Event do
  @moduledoc "Minimal immutable sender/subject activity, supplied by the trusted host after a guarded action or cap decision."
  alias EmailJanitor.Address
  @enforce_keys [:source_id, :message_id, :kind, :sender, :subject, :occurred_at]
  defstruct [:source_id, :message_id, :kind, :sender, :subject, :occurred_at]

  def new(source_id, message_id, kind, sender, subject, %DateTime{} = occurred_at)
      when kind in [:done, :would_have_done] and is_binary(message_id) and is_binary(subject) do
    with {:ok, source_id} <- Ecto.UUID.cast(source_id),
         true <- Regex.match?(~r/\A[0-9a-f]{1,32}\z/, message_id),
         {:ok, [sender]} <- Address.parse(sender),
         true <- String.valid?(subject) and byte_size(subject) <= 8192,
         {:ok, occurred_at} <- DateTime.shift_zone(occurred_at, "Etc/UTC") do
      subject =
        subject |> String.replace(~r/[\x00-\x1F\x7F]/u, " ") |> String.trim() |> bound(256)

      {:ok,
       %__MODULE__{
         source_id: source_id,
         message_id: message_id,
         kind: kind,
         sender: sender,
         subject: if(subject == "", do: "(no subject)", else: subject),
         occurred_at: %{occurred_at | microsecond: {elem(occurred_at.microsecond, 0), 6}}
       }}
    else
      _ -> {:error, :invalid_digest_event}
    end
  rescue
    _ -> {:error, :invalid_digest_event}
  end

  def new(_, _, _, _, _, _), do: {:error, :invalid_digest_event}

  defp bound(text, max) when byte_size(text) <= max, do: text

  defp bound(text, max) do
    value = binary_part(text, 0, max)
    if String.valid?(value), do: value, else: bound(text, max - 1)
  end

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Digest.Event<[METADATA]>"
  end
end
