defmodule EmailJanitor.Identity do
  @moduledoc "Resolve correspondence identities without letting relay domains protect external pitches."
  alias EmailJanitor.{Address, Inbox, Message}

  def resolve(%Message{} = message, %Inbox{} = inbox) do
    with {:ok, from} <- Address.parse(Message.header(message, "from")),
         {:ok, reply_to} <- optional(message, "reply-to") do
      relay? = length(from) == 1 and hd(from) in inbox.relay_addresses
      own_domain = Address.domain(inbox.address)

      with {:ok, originals} <- originals(message, relay?) do
        own_from? =
          not Address.shared?(own_domain) and
            Enum.any?(from, &Address.within?(Address.domain(&1), own_domain))

        addresses = Enum.uniq(from ++ reply_to ++ originals)

        external =
          if Address.shared?(own_domain),
            do: addresses,
            else: Enum.reject(addresses, &Address.within?(Address.domain(&1), own_domain))

        cond do
          own_from? and (not relay? or external == []) ->
            {:keep, :own_domain}

          true ->
            checked =
              if external != [] and (relay? or not own_from?), do: external, else: addresses

            {:ok, checked |> Enum.flat_map(&Address.contact_keys/1) |> Enum.uniq() |> Enum.sort()}
        end
      end
    end
  end

  defp optional(message, key) do
    case Message.header(message, key) do
      nil -> {:ok, []}
      value -> Address.parse(value)
    end
  end

  defp originals(message, true) do
    with {:ok, a} <- optional(message, "x-original-sender"),
         {:ok, b} <- optional(message, "x-original-from"),
         do: {:ok, a ++ b}
  end

  defp originals(_, false), do: {:ok, []}
end
