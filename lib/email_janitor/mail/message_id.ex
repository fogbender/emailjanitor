defmodule EmailJanitor.Mail.MessageID do
  @moduledoc "Strict SES RFC822 Message-ID projection for scoped sent-record matching; never authentication for feedback."

  def provider_id(value) when is_binary(value) and byte_size(value) <= 600 do
    value = String.trim(value)

    value =
      if String.starts_with?(value, "<") and String.ends_with?(value, ">"),
        do: binary_part(value, 1, byte_size(value) - 2),
        else: value

    with [id, domain] <- String.split(value, "@"),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,256}\z/, id),
         true <- byte_size(domain) <= 253,
         domain = String.downcase(domain),
         true <- domain == "amazonses.com" or String.ends_with?(domain, ".amazonses.com"),
         true <-
           Enum.all?(
             String.split(domain, "."),
             &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, &1)
           ) do
      {:ok, id}
    else
      _ -> {:error, :unknown_message_id}
    end
  rescue
    _ -> {:error, :unknown_message_id}
  end

  def provider_id(_), do: {:error, :unknown_message_id}
end
