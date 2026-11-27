defmodule EmailJanitor.Mail.Message do
  @moduledoc "Transient outgoing content, with no destination or sender capability."
  alias EmailJanitor.Content
  @enforce_keys [:subject, :text]
  defstruct [:subject, :text]

  def new(subject, %Content{} = text) when is_binary(subject) do
    body = Content.read(text)

    if byte_size(subject) in 1..256 and String.valid?(subject) and
         not String.contains?(subject, ["\r", "\n", <<0>>]) and is_binary(body) and
         byte_size(body) in 1..131_072 and String.valid?(body) do
      {:ok, %__MODULE__{subject: Content.new(subject), text: text}}
    else
      {:error, :invalid_outgoing_content}
    end
  end

  def new(_, _), do: {:error, :invalid_outgoing_content}

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Mail.Message<[REDACTED]>"
  end

  defimpl Jason.Encoder do
    def encode(_, opts), do: Jason.Encode.string("[REDACTED]", opts)
  end
end
