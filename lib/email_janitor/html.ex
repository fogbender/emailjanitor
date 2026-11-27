defmodule EmailJanitor.HTML do
  @moduledoc "Readable notification text and link targets, excluding executable/hidden document metadata."
  alias EmailJanitor.Content

  def readable(%Content{} = content, limit \\ 16_000) when is_integer(limit) and limit > 0 do
    with {:ok, document} <- Floki.parse_document(Content.read(content)) do
      document
      |> Floki.filter_out("script, style, title, head, template")
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

  defp fragments({tag, attrs, children}) do
    if hidden?(attrs) do
      []
    else
      href = if tag == "a", do: for({"href", value} <- attrs, do: value), else: []
      href ++ fragments(children)
    end
  end

  defp fragments(_), do: []

  defp hidden?(attrs) do
    style =
      attrs
      |> Enum.filter(fn {name, _} -> name == "style" end)
      |> Enum.map_join(";", &elem(&1, 1))
      |> declarations()

    display = style["display"]

    visible_display =
      display in ~w(block inline inline-block flex inline-flex grid inline-grid table table-row table-cell contents flow-root initial unset inherit)

    (Enum.any?(attrs, fn {name, _} -> name == "hidden" end) and not visible_display) or
      display == "none" or style["visibility"] in ["hidden", "collapse"] or
      style["opacity"] in ["0", "0.0", "0%"] or style["mso-hide"] == "all" or
      (style["max-height"] in ["0", "0px", "0em", "0rem"] and style["overflow"] == "hidden")
  end

  # Best-effort inline declarations, not a browser/CSS renderer. Ignore comments
  # and honor !important/last-declaration precedence for the common hiding rules.
  # aria-hidden is accessibility metadata and must never hide visible text here.
  defp declarations(source) do
    source
    |> String.replace(~r/\/\*.*?\*\//s, "")
    |> String.split(";")
    |> Enum.reduce(%{}, fn declaration, acc ->
      case String.split(declaration, ":", parts: 2) do
        [key, value] ->
          key = key |> String.trim() |> String.downcase()
          value = value |> String.trim() |> String.downcase()
          important? = Regex.match?(~r/!\s*important\s*$/, value)
          value = value |> String.replace(~r/!\s*important\s*$/, "") |> String.trim()

          case Map.get(acc, key) do
            {_, true} when not important? -> acc
            _ -> Map.put(acc, key, {value, important?})
          end

        _ ->
          acc
      end
    end)
    |> Map.new(fn {key, {value, _}} -> {key, value} end)
  end
end
