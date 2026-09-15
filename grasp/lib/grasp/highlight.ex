defmodule Grasp.Highlight do
  @moduledoc """
  Renders a function record as syntax-highlighted HTML with a clickable span over every
  resolved call.

  Lumis (tree-sitter) emits one `div.l-line` per source line whose children are text runs
  and `span.l-*` runs that may nest — an interpolation is a `span.l-function-call` inside
  a `span.l-string`. Each text run becomes a piece carrying the class of its innermost
  span, positioned by counting characters along the line.

  A call range (from the index, `{line, column}` pairs with an exclusive end column, in
  file coordinates) may start or end inside a run and may span lines; run text is
  therefore split at range boundaries, and consecutive pieces inside the same range on the
  same line are wrapped together. Output is one `span.line` per source line so the viewer
  can address lines, with Lumis' classes on highlighted runs and bare text elsewhere.
  """

  @type opts :: [
          card_id: pos_integer(),
          open_targets: [String.t()],
          external?: (String.t() -> boolean())
        ]

  @doc "Highlighted HTML for `record` with clickable call spans; see the moduledoc."
  @spec render(map(), opts()) :: Phoenix.HTML.safe()
  def render(record, opts) do
    card_id = Keyword.fetch!(opts, :card_id)
    open = MapSet.new(Keyword.get(opts, :open_targets, []))
    external? = Keyword.get(opts, :external?, fn _ -> false end)
    first_line = record["span"]["start_line"]

    ranges =
      for call <- record["calls"], %{"start" => [sl, sc], "end" => [el, ec]} = call["range"] do
        %{target: call["target"], start: {sl, sc}, end: {el, ec}}
      end

    source = record["source"]
    by_line = source |> pieces(first_line) |> Enum.group_by(& &1.line)

    # Lines are driven by the source, not by the tokens: a blank line carries no piece, and
    # numbering it from the token groups alone would drop it and skip a number in the gutter.
    last_line = first_line + length(String.split(source, "\n")) - 1

    html =
      Enum.map_join(first_line..last_line, "\n", fn line ->
        body =
          by_line
          |> Map.get(line, [])
          |> Enum.flat_map(&split_at_ranges(&1, ranges))
          |> wrap_calls(ranges, card_id, open, external?)

        ~s(<span class="line" data-line="#{line}"><span class="ln">#{line}</span>#{body}</span>)
      end)

    {:safe, html}
  end

  # Each Lumis text run becomes a piece %{line, col, text, css}; col is the 1-based start
  # column, css the class of the run's innermost span (nil for unhighlighted text).
  defp pieces(source, first_line) do
    lines =
      source
      |> Lumis.highlight!(formatter: {:html_linked, language: "elixir"})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("div.l-line")
      |> Enum.map(&LazyHTML.to_tree/1)

    lines
    |> Enum.with_index(first_line)
    |> Enum.flat_map(fn {[{"div", _attrs, children}], line} ->
      {pieces, _col} = Enum.reduce(children, {[], 1}, &runs(&1, nil, line, &2))
      Enum.reverse(pieces)
    end)
  end

  defp runs(text, css, line, {acc, col}) when is_binary(text) do
    text = String.replace_suffix(text, "\n", "")

    if text == "" do
      {acc, col}
    else
      {[%{line: line, col: col, text: text, css: css} | acc], col + String.length(text)}
    end
  end

  defp runs({"span", attrs, children}, _outer_css, line, acc) do
    css = attrs |> List.keyfind("class", 0, {"class", nil}) |> elem(1)
    Enum.reduce(children, acc, &runs(&1, css, line, &2))
  end

  defp runs(_other, _css, _line, acc), do: acc

  defp split_at_ranges(piece, ranges) do
    piece_end = piece.col + String.length(piece.text)

    cuts =
      ranges
      |> Enum.flat_map(fn range ->
        [line_bound(range, piece.line, :start), line_bound(range, piece.line, :end)]
      end)
      |> Enum.filter(&(&1 > piece.col and &1 < piece_end))
      |> Enum.uniq()
      |> Enum.sort()

    {pieces, _} =
      Enum.reduce(cuts ++ [piece_end], {[], piece.col}, fn cut, {acc, from} ->
        text = String.slice(piece.text, from - piece.col, cut - from)
        {[%{piece | col: from, text: text} | acc], cut}
      end)

    Enum.reverse(pieces)
  end

  defp wrap_calls(pieces, ranges, card_id, open, external?) do
    pieces
    |> Enum.chunk_by(&covering(&1, ranges))
    |> Enum.map_join(fn [first | _] = chunk ->
      inner = Enum.map_join(chunk, &token_html/1)

      case covering(first, ranges) do
        nil ->
          inner

        %{target: target} ->
          attrs =
            ~s( data-target="#{escape(target)}" data-open="#{MapSet.member?(open, target)}") <>
              ~s( data-external="#{escape(to_string(external?.(target)))}" phx-click="open_call" phx-value-card="#{escape(to_string(card_id))}" phx-value-target="#{escape(target)}")

          ~s(<span class="call"#{attrs}>#{inner}</span>)
      end
    end)
  end

  # Whitespace is never part of a callee, so a range that continues onto a new line does
  # not swallow that line's indentation.
  defp covering(piece, ranges) do
    if String.trim(piece.text) == "" do
      nil
    else
      Enum.find(ranges, fn range ->
        piece.col >= line_bound(range, piece.line, :start) and
          piece.col < line_bound(range, piece.line, :end)
      end)
    end
  end

  # The columns a range occupies on `line`: a range covers whole lines between its start and end.
  defp line_bound(%{start: {sl, sc}, end: {el, _ec}}, line, :start),
    do: if(line == sl, do: sc, else: if(line > sl and line <= el, do: 1, else: :infinity))

  defp line_bound(%{start: {sl, _sc}, end: {el, ec}}, line, :end),
    do: if(line == el, do: ec, else: if(line >= sl and line < el, do: :infinity, else: -1))

  defp token_html(%{text: text, css: nil}), do: escape(text)
  defp token_html(%{text: text, css: css}), do: ~s(<span class="#{css}">#{escape(text)}</span>)

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
