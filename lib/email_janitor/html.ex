defmodule EmailJanitor.HTML do
  @moduledoc "Readable notification text and link targets, excluding executable/hidden document metadata."
  alias EmailJanitor.Content

  def readable(%Content{} = content, limit \\ 16_000) when is_integer(limit) and limit > 0 do
    with {:ok, document} <- Floki.parse_document(Content.read(content)) do
      document
      |> Floki.filter_out("script, style, title, head")
      |> fragments()
      |> Enum.join(" ")
      |> String.replace(~r/\s+/u, " ")
      |> String.slice(0, limit)
      |> Content.new()
      |> then(&{:ok, &1})
    else
      _ -> {:error, :invalid_html}
    end
  rescue
    _ -> {:error, :invalid_html}
  end

  defp fragments(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &fragments/1)
  defp fragments(text) when is_binary(text), do: [text]

  defp fragments({"a", attrs, children}) do
    href = for {"href", value} <- attrs, do: value
    href ++ fragments(children)
  end

  defp fragments({_tag, _attrs, children}), do: fragments(children)
  defp fragments(_), do: []
end
