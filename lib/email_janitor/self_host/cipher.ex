defmodule EmailJanitor.SelfHost.Cipher do
  @moduledoc false
  alias EmailJanitor.Content
  @max 65_536

  def seal(%Content{} = key, label, id, %Content{} = content) do
    with {:ok, aad} <- aad(label, id),
         bytes <- Content.read(content),
         true <- byte_size(bytes) <= @max,
         secret <- Content.read(key),
         true <- byte_size(secret) == 32 do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, bytes, aad, 16, true)

      {:ok, <<1, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>}
    else
      _ -> {:error, :credential_seal_failed}
    end
  rescue
    _ -> {:error, :credential_seal_failed}
  end

  def open(
        %Content{} = key,
        label,
        id,
        <<1, iv::binary-size(12), tag::binary-size(16), bytes::binary>>
      )
      when byte_size(bytes) <= @max do
    with {:ok, aad} <- aad(label, id),
         secret <- Content.read(key),
         true <- byte_size(secret) == 32,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, bytes, aad, tag, false) do
      {:ok, Content.new(plaintext)}
    else
      _ -> {:error, :credential_open_failed}
    end
  rescue
    _ -> {:error, :credential_open_failed}
  end

  def open(_, _, _, _), do: {:error, :credential_open_failed}

  defp aad(label, id) when is_binary(label) and is_binary(id) do
    if byte_size(label) in 1..128 and byte_size(id) in 1..256 and
         String.valid?(label) and String.valid?(id) do
      {:ok, :erlang.term_to_binary({"emailjanitor/selfhost/v1", label, id})}
    else
      :error
    end
  end

  defp aad(_, _), do: :error
end
