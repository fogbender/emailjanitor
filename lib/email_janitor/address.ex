defmodule EmailJanitor.Address do
  @moduledoc "Conservative mailbox normalization and public-suffix-aware contact keys."

  @shared ~w(gmail.com googlemail.com qq.com outlook.com hotmail.com live.com
    yahoo.com icloud.com foxmail.com me.com aol.com proton.me protonmail.com)
  @local ~r/\A[a-z0-9.!\#$%&'*+\/=?^_`{|}~-]+\z/
  @label ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  def parse(header) when is_binary(header) do
    if String.valid?(header) and byte_size(header) <= 8192 and
         not String.contains?(header, ["\r", "\n", <<0>>]) do
      {"from", values} = Mail.Parsers.RFC2822.parse_header("From: " <> header, [])

      values
      |> List.wrap()
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        address =
          case value do
            {_, address} -> address
            address when is_binary(address) -> address
            _ -> nil
          end

        case normalize(address) do
          {:ok, address} -> {:cont, {:ok, [address | acc]}}
          _ -> {:halt, {:error, :invalid_address}}
        end
      end)
      |> case do
        {:ok, []} -> {:error, :invalid_address}
        {:ok, values} -> {:ok, Enum.uniq(Enum.reverse(values))}
        error -> error
      end
    else
      {:error, :invalid_address}
    end
  rescue
    _ -> {:error, :invalid_address}
  end

  def parse(_), do: {:error, :invalid_address}

  def normalize(value) when is_binary(value) do
    value = String.downcase(String.trim(value))

    with true <- String.valid?(value) and byte_size(value) <= 254,
         [local, domain] <- String.split(value, "@"),
         true <- byte_size(local) in 1..64 and Regex.match?(@local, local),
         false <-
           String.starts_with?(local, ".") or String.ends_with?(local, ".") or
             String.contains?(local, ".."),
         domain = String.trim_trailing(domain, "."),
         true <- valid_domain?(domain),
         {:ok, _} <- Domainatrex.parse(domain) do
      {:ok, local <> "@" <> domain}
    else
      _ -> {:error, :invalid_address}
    end
  end

  def normalize(_), do: {:error, :invalid_address}
  def domain(address), do: address |> String.split("@") |> List.last()

  def shared?(domain) do
    Enum.any?(@shared, &(domain == &1 or String.ends_with?(domain, "." <> &1)))
  end

  def within?(domain, parent), do: domain == parent or String.ends_with?(domain, "." <> parent)

  def contact_keys(address) do
    domain = domain(address)

    if shared?(domain) do
      [address]
    else
      {:ok, %{domain: name, tld: suffix}} = Domainatrex.parse(domain)
      root = name <> "." <> suffix
      labels = String.split(domain, ".")
      count = length(labels) - length(String.split(root, "."))
      for offset <- 0..count, do: labels |> Enum.drop(offset) |> Enum.join(".")
    end
  end

  defp valid_domain?(domain) do
    byte_size(domain) <= 253 and
      Enum.all?(String.split(domain, "."), fn label ->
        byte_size(label) in 1..63 and Regex.match?(@label, label)
      end)
  end
end
