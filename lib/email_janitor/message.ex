defmodule EmailJanitor.Message do
  @moduledoc "Transient Gmail message; content is never part of a durable action record."
  alias EmailJanitor.Content
  @enforce_keys [:id, :thread_id, :headers, :labels]
  @derive {Inspect, only: [:id, :thread_id, :labels]}
  defstruct [:id, :thread_id, :headers, :labels, :received_at, :cleanup_target, body: nil]
  @type t :: %__MODULE__{}

  def header(%__MODULE__{headers: headers}, name) do
    case Enum.filter(headers, fn {key, _} -> String.downcase(key) == name end) do
      [] -> nil
      [{_, value}] -> value
      _ -> :duplicate
    end
  end

  def in_inbox?(%__MODULE__{labels: labels}), do: "INBOX" in labels

  @doc "Host-selected eligibility is separate from Gmail's raw INBOX state."
  def cleanup_target?(%__MODULE__{} = message),
    do: in_inbox?(message) and message.cleanup_target != false

  def fingerprint(messages) do
    messages
    |> Enum.map(&{&1.id, Enum.sort(&1.labels)})
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def with_body(%__MODULE__{} = message, body) when is_binary(body),
    do: %{message | body: Content.new(body)}
end
