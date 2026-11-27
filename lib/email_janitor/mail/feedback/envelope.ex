defmodule EmailJanitor.Mail.Feedback.Envelope do
  @moduledoc "Body-free SMTP routing hints only. Neither From nor SES verdicts authorize commands."
  alias EmailJanitor.{Address, Content}
  alias EmailJanitor.Mail.{Incoming, RFCMessageID}
  @enforce_keys [:ses_id, :from, :rfc_message_id, :received_at, :expires_at, :signup_allowed]
  defstruct @enforce_keys

  def new(%Incoming{} = incoming, %Content{} = raw, expected_recipient) do
    with true <- expected_recipient in incoming.recipients,
         false <- incoming.verdicts["dmarcVerdict"] == "FAIL",
         false <- incoming.envelope_from == "",
         {:ok, headers} <- headers(Content.read(raw)),
         {:ok, [from]} <- Address.parse(one(headers, "from")),
         false <- from == expected_recipient,
         {:ok, rfc_id} <- RFCMessageID.canonical(one(headers, "message-id")),
         true <- human?(headers) do
      allowed =
        incoming.envelope_from == from and
          Enum.all?(
            ~w(spamVerdict virusVerdict spfVerdict dkimVerdict dmarcVerdict),
            &(incoming.verdicts[&1] == "PASS")
          )

      {:ok,
       %__MODULE__{
         ses_id: incoming.id,
         from: from,
         rfc_message_id: rfc_id,
         received_at:
           DateTime.add(incoming.expires_at, -EmailJanitor.Mail.Spool.processing_ttl_seconds()),
         expires_at: incoming.expires_at,
         signup_allowed: allowed
       }}
    else
      false -> :ignored
      true -> :ignored
      _ -> :rejected
    end
  rescue
    _ -> :rejected
  end

  defp human?(headers) do
    auto = one(headers, "auto-submitted")
    precedence = one(headers, "precedence")

    (is_nil(auto) or (is_binary(auto) and String.downcase(auto) == "no")) and
      precedence != :duplicate and one(headers, "list-id") == nil and
      one(headers, "x-auto-response-suppress") == nil and
      not (is_binary(precedence) and String.downcase(precedence) in ~w(bulk list junk))
  end

  defp one(headers, key) do
    case for {^key, v} <- headers, do: v do
      [] -> nil
      [value] -> value
      _ -> :duplicate
    end
  end

  # Only RFC header framing is handled here, preserving duplicate detection.
  # Address syntax is delegated to the existing maintained Mail parser.
  defp headers(raw) when is_binary(raw) do
    case :binary.split(raw, "\r\n\r\n") do
      [head, _] when byte_size(head) <= 65_536 ->
        with true <- String.valid?(head),
             lines = String.split(head, "\r\n"),
             true <- length(lines) <= 256,
             {:ok, unfolded} <- unfold(lines, []) do
          Enum.reduce_while(unfolded, {:ok, []}, fn line, {:ok, acc} ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if byte_size(line) <= 8192 and Regex.match?(~r/\A[A-Za-z0-9-]+\z/, name),
                  do: {:cont, {:ok, [{String.downcase(name), String.trim(value)} | acc]}},
                  else: {:halt, {:error, :invalid_headers}}

              _ ->
                {:halt, {:error, :invalid_headers}}
            end
          end)
        else
          _ -> {:error, :invalid_headers}
        end

      _ ->
        {:error, :invalid_headers}
    end
  end

  defp headers(_), do: {:error, :invalid_headers}
  defp unfold([], acc), do: {:ok, Enum.reverse(acc)}

  defp unfold([<<first, _::binary>> = line | rest], [previous | acc]) when first in [32, 9],
    do: unfold(rest, [previous <> " " <> String.trim(line) | acc])

  defp unfold([<<first, _::binary>> | _], []) when first in [32, 9],
    do: {:error, :invalid_headers}

  defp unfold([line | rest], acc), do: unfold(rest, [line | acc])
end
