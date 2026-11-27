defmodule EmailJanitor.Mail.RFCMessageID do
  @moduledoc "Bounded canonical Message-ID reference. A match is not authentication; feedback separately proves a fresh own-Sent copy."

  def canonical(value) when is_binary(value) and byte_size(value) <= 600 do
    value = String.trim(value)

    value =
      if String.starts_with?(value, "<") and String.ends_with?(value, ">"),
        do: binary_part(value, 1, byte_size(value) - 2),
        else: value

    with [_, local, domain] <-
           Regex.run(
             ~r/\A([A-Za-z0-9.!\x23$%&'*+\/=?^_`{|}~-]{1,256})@([A-Za-z0-9.-]{1,253})\z/,
             value
           ),
         true <-
           Enum.all?(
             String.split(domain, "."),
             &Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, &1)
           ) do
      {:ok, local <> "@" <> String.downcase(domain)}
    else
      _ -> {:error, :invalid_message_id}
    end
  rescue
    _ -> {:error, :invalid_message_id}
  end

  def canonical(_), do: {:error, :invalid_message_id}

  @doc "Stable body-free UUID, scoped to the verified mailbox and canonical RFC Message-ID."
  def request_id(inbox_id, canonical_id) when is_binary(inbox_id) do
    with true <- byte_size(inbox_id) in 1..256,
         {:ok, ^canonical_id} <- canonical(canonical_id) do
      <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
        :crypto.hash(:sha256, ["emailjanitor.feedback.v1", <<0>>, inbox_id, <<0>>, canonical_id])

      Ecto.UUID.load(<<a::48, 5::4, b::12, 2::2, c::62>>)
    else
      _ -> {:error, :invalid_message_id}
    end
  end

  def request_id(_, _), do: {:error, :invalid_message_id}
end
