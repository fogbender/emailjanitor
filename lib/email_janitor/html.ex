defmodule EmailJanitor.HTML do
  @moduledoc "Readable notification text and link targets, excluding executable/hidden document metadata."
  alias EmailJanitor.Content

  def readable(%Content{} = content, limit \\ 16_000) when is_integer(limit) and limit > 0 do
    with true <- byte_size(Content.read(content)) <= 262_144,
         true <- length(:binary.matches(Content.read(content), "<")) <= 4096,
         {:ok, document} <- Floki.parse_document(Content.read(content)) do
      document
      |> Floki.filter_out("script, style, title, head, template")
      |> fragments(:visible)
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

  defp fragments(nodes, visibility) when is_list(nodes),
    do: Enum.flat_map(nodes, &fragments(&1, visibility))

  defp fragments(text, :visible) when is_binary(text), do: [text]
  defp fragments(text, _) when is_binary(text), do: []

  defp fragments({tag, attrs, children}, inherited_visibility) do
    style = inline_style(attrs)

    visibility =
      case style["visibility"] do
        value when value in ["hidden", "collapse"] -> :hidden
        value when value in ["visible", "initial"] -> :visible
        _ -> inherited_visibility
      end

    if hidden?(attrs, style) do
      []
    else
      href =
        if tag == "a" and visibility == :visible,
          do: for({"href", value} <- attrs, do: value),
          else: []

      href ++ fragments(children, visibility)
    end
  end

  defp fragments(_, _), do: []

  defp inline_style(attrs) do
    attrs
    |> Enum.filter(fn {name, _} -> name == "style" end)
    |> Enum.map_join(";", &elem(&1, 1))
    |> declarations()
  end

  defp hidden?(attrs, style) do
    display = style["display"]

    visible_display =
      display in ~w(block inline inline-block flex inline-flex grid inline-grid table inline-table table-row table-cell table-caption table-column table-column-group table-row-group table-header-group table-footer-group list-item contents flow-root initial unset inherit) or
        display in [
          "block flow",
          "inline flow",
          "block flow-root",
          "inline flow-root",
          "block flex",
          "inline flex",
          "block grid",
          "inline grid",
          "block table",
          "inline table"
        ]

    (Enum.any?(attrs, fn {name, _} -> name == "hidden" end) and not visible_display) or
      display == "none" or style["opacity"] in ["0", "0.0", "0%"] or
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
