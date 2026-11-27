defmodule EmailJanitor.Gmail.Parser do
  @moduledoc "Transient conversion of generated Gmail SDK messages; attachments are not fetched."
  alias EmailJanitor.{Content, HTML, Message}
  alias GoogleApi.Gmail.V1.Model, as: Google
  @max_encoded_part 1_400_000
  @max_text 1_000_000

  def message(%Google.Message{} = value) do
    with true <- valid_id?(value.id) and valid_id?(value.threadId),
         labels = value.labelIds || [],
         true <- is_list(labels) and Enum.all?(labels, &is_binary/1),
         %Google.MessagePart{} = payload <- value.payload,
         {:ok, headers} <- headers(payload.headers),
         {:ok, fragments} <- parts(payload, 0),
         true <- fragments != [],
         true <-
           not omitted_attachment?(payload, 0) or Enum.any?(fragments, &(String.trim(&1) != "")),
         body = Enum.join(fragments, "\n"),
         true <- byte_size(body) <= @max_text,
         {:ok, date} <- date(value.internalDate) do
      # All MIME text is now readable plain text, including HTML alternatives.
      # Prevent consumers from HTML-decoding the already-decoded content again.
      headers = Enum.reject(headers, fn {k, _} -> String.downcase(k) == "content-type" end)

      {:ok,
       %Message{
         id: value.id,
         thread_id: value.threadId,
         labels: labels,
         headers: [{"Content-Type", "text/plain"} | headers],
         body: Content.new(body),
         received_at: date
       }}
    else
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :invalid_message}
  catch
    _, _ -> {:error, :invalid_message}
  end

  def message(_), do: {:error, :invalid_message}

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,200}\z/, id)

  defp headers(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      %Google.MessagePartHeader{name: name, value: value}, {:ok, acc}
      when is_binary(name) and is_binary(value) ->
        {:cont, {:ok, [{name, value} | acc]}}

      _, _ ->
        {:halt, {:error, :invalid_headers}}
    end)
  end

  defp headers(_), do: {:error, :invalid_headers}

  defp parts(_, depth) when depth > 30, do: {:error, :invalid_mime}

  defp parts(%Google.MessagePart{filename: filename}, _)
       when is_binary(filename) and filename != "",
       do: {:ok, []}

  defp parts(%Google.MessagePart{} = part, depth) do
    with {:ok, own} <- text(part),
         children = part.parts || [],
         true <- is_list(children) and length(children) <= 100,
         {visible, omitted} = optional_visual_parts(part.mimeType, children),
         {:ok, rest} <-
           Enum.reduce_while(visible, {:ok, []}, fn child, {:ok, acc} ->
             case parts(child, depth + 1) do
               {:ok, text} -> {:cont, {:ok, acc ++ text}}
               error -> {:halt, error}
             end
           end),
         true <- omitted == [] or Enum.any?(own ++ rest, &(String.trim(&1) != "")) do
      {:ok, own ++ rest}
    else
      _ -> {:error, :invalid_mime}
    end
  end

  defp parts(_, _), do: {:error, :invalid_mime}

  defp omitted_attachment?(_, depth) when depth > 30, do: true

  defp omitted_attachment?(%Google.MessagePart{filename: name}, _)
       when is_binary(name) and name != "",
       do: true

  defp omitted_attachment?(%Google.MessagePart{} = part, depth),
    do: Enum.any?(part.parts || [], &omitted_attachment?(&1, depth + 1))

  # AMP is an alternative representation, and related inline images are visual
  # resources. Omit them only when supported readable text is also available.
  # Other unsupported text (calendar/enriched) must still fail conservatively.
  defp optional_visual_parts("multipart/alternative", children) do
    if Enum.any?(
         children,
         &(&1.mimeType in ["text/plain", "text/html"] and &1.filename in [nil, ""])
       ) do
      Enum.split_with(children, &(&1.mimeType != "text/x-amp-html"))
    else
      {children, []}
    end
  end

  defp optional_visual_parts("multipart/related", children) do
    Enum.split_with(children, fn child ->
      not (is_binary(child.mimeType) and String.starts_with?(child.mimeType, "image/") and
             child.parts in [nil, []])
    end)
  end

  defp optional_visual_parts(_, children), do: {children, []}

  defp text(%Google.MessagePart{
         mimeType: type,
         body: %Google.MessagePartBody{data: data, attachmentId: nil}
       })
       when type in ["text/plain", "text/html"] and is_binary(data) do
    with true <- byte_size(data) <= @max_encoded_part,
         {:ok, decoded} <- Base.url_decode64(data, padding: false),
         true <- String.valid?(decoded) and byte_size(decoded) <= @max_text do
      if type == "text/html" do
        case HTML.readable(Content.new(decoded), @max_text) do
          {:ok, text} -> {:ok, [Content.read(text)]}
          _ -> {:error, :invalid_mime}
        end
      else
        {:ok, [decoded]}
      end
    else
      _ -> {:error, :invalid_mime}
    end
  end

  # A body delivered by reference is not an empty body. Preserve mail rather
  # than classify partial input while referenced-body fetching is unsupported.
  defp text(%Google.MessagePart{
         mimeType: type,
         body: %Google.MessagePartBody{data: nil, attachmentId: nil, size: size}
       })
       when type in ["text/plain", "text/html"] and size in [nil, 0],
       do: {:ok, [""]}

  defp text(%Google.MessagePart{mimeType: "multipart/" <> _}), do: {:ok, []}
  defp text(_), do: {:error, :invalid_mime}

  defp date(nil), do: {:ok, nil}

  defp date(value) when is_binary(value) do
    with {n, ""} when n >= 0 <- Integer.parse(value),
         {:ok, date} <- DateTime.from_unix(n, :millisecond),
         do: {:ok, date}
  end

  defp date(_), do: {:error, :invalid_date}
end
