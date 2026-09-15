defmodule Grasp.Highlight do
  @moduledoc """
  Renders a function record as syntax-highlighted HTML with a clickable span over every
  resolved call.

  Makeup's Elixir lexer produces tokens without positions, so the tokens are walked while
  tracking line and column against the record's source. A call range (from the index,
  `{line, column}` pairs with an exclusive end column, in file coordinates) may start or
  end inside a token and may span lines; token text is therefore split at range
  boundaries and at newlines, and consecutive pieces inside the same range on the same
  line are wrapped together. Output is one `span.line` per source line so the viewer can
  address lines, with Makeup's short CSS classes on tokens.
  """

  alias Makeup.Lexers.ElixirLexer
  alias Makeup.Token.Utils

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

    pieces = record["source"] |> ElixirLexer.lex() |> pieces(first_line)

    html =
      pieces
      |> Enum.group_by(& &1.line)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {line, line_pieces} ->
        body =
          line_pieces
          |> Enum.flat_map(&split_at_ranges(&1, ranges))
          |> wrap_calls(ranges, card_id, open, external?)

        ~s(<span class="line" data-line="#{line}"><span class="ln">#{line}</span>#{body}</span>)
      end)

    {:safe, html}
  end

  # One piece per token per line: %{line, col, text, css}; col is the 1-based start column.
  defp pieces(tokens, first_line) do
    {pieces, _pos} =
      Enum.reduce(tokens, {[], {first_line, 1}}, fn {type, _meta, value}, {acc, {line, col}} ->
        css = Utils.css_class_for_token_type(type)
        text = IO.chardata_to_string(value)
        segments = String.split(text, "\n")
        last = length(segments) - 1

        {acc, pos} =
          segments
          |> Enum.with_index()
          |> Enum.reduce({acc, {line, col}}, fn {segment, i}, {acc, {line, col}} ->
            acc =
              if segment == "",
                do: acc,
                else: [%{line: line, col: col, text: segment, css: css} | acc]

            if i < last,
              do: {acc, {line + 1, 1}},
              else: {acc, {line, col + String.length(segment)}}
          end)

        {acc, pos}
      end)

    Enum.reverse(pieces)
  end

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
              ~s( data-external="#{external?.(target)}" phx-click="open_call" phx-value-card="#{card_id}" phx-value-target="#{escape(target)}")

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
