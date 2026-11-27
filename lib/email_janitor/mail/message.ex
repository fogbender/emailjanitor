defmodule EmailJanitor.Mail.Message do
  @moduledoc "Transient outgoing content, with no destination or sender capability."
  alias EmailJanitor.Content
  alias EmailJanitor.Mail.RFCMessageID
  # At most 3x form-urlencoding is below 10 MB even before SES's separate
  # MIME/base64 message limit. SDK wire tests exercise this worst-case bound.
  @max_text_bytes 3_145_728
  @enforce_keys [:subject, :text]
  defstruct [:subject, :text, in_reply_to: nil, references: []]

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

  @doc "A transient reply with canonical references; sender and recipient remain host-owned."
  def new(subject, text, []) do
    new(subject_text(subject), text)
  end

  def new(subject, %Content{} = text, opts) when is_list(opts) do
    subject = subject_text(subject)

    with true <- Keyword.keyword?(opts),
         true <- Enum.sort(Keyword.keys(opts)) in [[:in_reply_to], [:in_reply_to, :references]],
         id when is_binary(id) <- opts[:in_reply_to],
         {:ok, ^id} <- RFCMessageID.canonical(id),
         references = Keyword.get(opts, :references, [id]),
         true <- is_list(references) and length(references) in 1..20,
         true <- length(Enum.uniq(references)) == length(references),
         true <- Enum.all?(references, &(RFCMessageID.canonical(&1) == {:ok, &1})),
         true <- List.last(references) == id,
         true <- Enum.reduce(references, 0, &(byte_size(&1) + 3 + &2)) <= 900,
         true <- is_binary(subject) and byte_size(subject) <= 980 and String.valid?(subject),
         false <- Regex.match?(~r/[\x00-\x1F\x7F]/u, subject),
         body = Content.read(text),
         true <- byte_size(body) in 1..64_000 and String.valid?(body) do
      {:ok,
       %__MODULE__{
         subject: Content.new(subject),
         text: text,
         in_reply_to: id,
         references: references
       }}
    else
      _ -> {:error, :invalid_outgoing_content}
    end
  rescue
    _ -> {:error, :invalid_outgoing_content}
  end

  def new(_, _, _), do: {:error, :invalid_outgoing_content}

  @doc false
  def validate(%__MODULE__{in_reply_to: nil, references: []} = message),
    do: new(subject_text(message.subject), message.text)

  def validate(%__MODULE__{} = message),
    do:
      new(message.subject, message.text,
        in_reply_to: message.in_reply_to,
        references: message.references
      )

  defp subject_text(%Content{} = subject), do: Content.read(subject)
  defp subject_text(subject), do: subject
  def max_text_bytes, do: @max_text_bytes

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Mail.Message<[REDACTED]>"
  end

  defimpl Jason.Encoder do
    def encode(_, opts), do: Jason.Encode.string("[REDACTED]", opts)
  end
end
