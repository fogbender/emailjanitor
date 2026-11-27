defmodule EmailJanitor.Mail.Message do
  @moduledoc "Transient outgoing content, with no destination or sender capability."
  alias EmailJanitor.Content
  # At most 3x form-urlencoding is below 10 MB even before SES's separate
  # MIME/base64 message limit. SDK wire tests exercise this worst-case bound.
  @max_text_bytes 3_145_728
  @enforce_keys [:subject, :text]
  defstruct [:subject, :text]

  def new(subject, %Content{} = text) when is_binary(subject) do
    body = Content.read(text)

    if byte_size(subject) in 1..256 and String.valid?(subject) and
         not String.contains?(subject, ["\r", "\n", <<0>>]) and is_binary(body) and
         byte_size(body) in 1..@max_text_bytes and String.valid?(body) do
      {:ok, %__MODULE__{subject: Content.new(subject), text: text}}
    else
      {:error, :invalid_outgoing_content}
    end
  end

  def new(_, _), do: {:error, :invalid_outgoing_content}
  def max_text_bytes, do: @max_text_bytes

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Mail.Message<[REDACTED]>"
  end

  defimpl Jason.Encoder do
    def encode(_, opts), do: Jason.Encode.string("[REDACTED]", opts)
  end
end
