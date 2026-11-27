defmodule EmailJanitor.Digest.Renderer do
  @moduledoc "Render frozen metadata as transient plain text; never a persisted email body."
  alias EmailJanitor.Content
  alias EmailJanitor.Mail.Message
  @reserve 4096
  @max_digest_bytes 32_768

  def max_digest_bytes, do: @max_digest_bytes
  def metadata_budget, do: @max_digest_bytes - @reserve
  # Counting metadata under SQL locks must not construct a rendered body.
  def entry_bytes(entry), do: byte_size(entry.sender) + byte_size(entry.subject) + 3

  def message(snapshot, entries, footer \\ "")
      when is_binary(footer) and byte_size(footer) <= 2048 do
    done = Enum.filter(entries, &(&1.kind == :done))
    extras = Enum.filter(entries, &(&1.kind == :would_have_done))

    intro =
      if snapshot.first,
        do: "Reply to this email to teach Janitor what to keep or mark Done.\n\n",
        else: ""

    body = intro <> section("Marked Done", done) <> section("Would have been marked Done", extras)
    body = if footer == "", do: body, else: body <> "\n" <> footer <> "\n"
    Message.new("Email Janitor activity", Content.new(body))
  end

  defp section(_, []), do: ""
  defp section(title, entries), do: title <> "\n\n" <> Enum.map_join(entries, "", &line/1)
  defp line(entry), do: entry.sender <> "\n" <> entry.subject <> "\n\n"
end
