defmodule Grasp.Index.Heex do
  @moduledoc """
  Reads HEEx template text and reports the two things in it a reader can click through:
  the component tags, at the position the compiler reports for the call each one becomes,
  and the body of every interpolation, for `Grasp.Index.Extract` to parse as Elixir.

  Phoenix compiles `<.badge />` into a call to `badge/1` and `<Alias.Path.fun />` into a
  call to `Alias.Path.fun/1`, and the position it attaches to the two differs: a local tag
  carries the position of the `<` that opens it, a remote tag the position of the function
  name — one column past the last dot. `Grasp.Index.Join` pairs tracer events with call
  sites by line and column, so a site's `column` follows the compiler rather than the text:
  the `<` for a local tag, the function name's first character for a remote one. The
  `range` is the same shape for both, running from the character after the `<` through the
  end of the name, so a reader clicks `.badge` or `SampleAppWeb.Greeting.render` and
  nothing else.

  Positions are the file's. A template reaches this module with its own coordinates —
  line 1 of the text, and a heredoc's indentation already stripped from every line — so
  the caller passes `{first_line, indent}`: text line 1 is file line `first_line`, and text
  column 1 on every line is file column `indent + 1`. A template that starts mid-line (a
  single-line `~H"..."`) passes the file column of its first character as a third argument;
  it applies to the first line only.

  An interpolation — a `{...}` in a tag body or an attribute value, or an EEx expression
  tag (`<%= ... %>`, `<% ... %>`) — is Elixir, so its body is yielded rather than dropped:
  `interpolations/2,3` returns the text between the delimiters at the file position of its
  first character, with every continuation line prefixed by `indent` spaces so that parsing
  the text at that position reads file coordinates on every line. A body is yielded whole,
  whatever it says: `<% end %>` and `<%# a note %>` are yielded like any other, and the
  parser that fails on them makes no site.

  Three kinds of text are skipped, because none of them is a component call or Elixir:
  slot tags (`<:inner>`, which are not components), `<%!-- --%>` and `<!-- -->` comments,
  and the body of a `<script>` or `<style>` element, which HEEx treats as raw text where a
  brace is a brace and a `<` opens nothing.

  A `{...}` body is found by counting brace depth, not by parsing Elixir. A double-quoted
  string inside the body is read as a string, so the braces in `{String.replace(x, "}", "")}`
  are left uncounted, and a `\\"` inside one does not end it. Two kinds of brace are still
  counted: one inside a single-quoted charlist (`{f('}')}`), and one inside a string nested in
  a `#{}` interpolation, whose opening `"` reads as the end of the string it is written in;
  either ends the body early, where the truncated text parses into nothing. The quote of a
  `?\"` character literal opens a string the same way, so `{f(?\")}` never finds its closing
  brace and yields no body at all. An unbalanced brace swallows the rest of the template, as
  an unterminated `<%!--`, `<!--`, `<script>` or `<style>` does; an unterminated `<%` does
  not, since the scan resumes just past it. A body whose closing delimiter never arrives is
  yielded by neither function. An expression tag is read before a brace inside it is, so the
  map in `<%= %{a: 1} %>` belongs to the tag; a tag-shaped pattern inside a plain attribute
  string (`title="<.badge />"`) is still reported as a tag, which is harmless, since the
  compiler reports no call there and nothing lands on the site.
  """

  alias Grasp.Index.Extract

  @type site :: Extract.call_site()
  @type interpolation :: %{line: pos_integer(), column: pos_integer(), text: String.t()}

  # A local tag (`.name`) or a remote one (`Alias.Path.name`) directly after the `<`. The
  # lookahead keeps the match off names the HEEx tokenizer would read as one longer name.
  @tag ~r/\A(\.|(?:[A-Z]\w*\.)+)([a-z_]\w*[?!]?)(?![\w.\-?!])/

  # What may follow the name of a raw-text element, so `<scriptish>` stays an ordinary tag.
  defguardp raw_boundary(rest)
            when rest == <<>> or binary_part(rest, 0, 1) in [" ", "\t", "\r", "\n", ">", "/"]

  @doc """
  Scans `text` for component tags, returning a call site for each in document order.

  `first_line` is the file line of the text's first line and `indent` the number of
  columns every line sits to the right of the file's column 1. `first_line_column` is the
  file column of the text's very first character, for text that starts mid-line; it
  defaults to `indent + 1`, where a line of its own starts.
  """
  @spec tag_sites(String.t(), {pos_integer(), non_neg_integer()}) :: [site()]
  @spec tag_sites(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [site()]
  def tag_sites(text, first_line_and_indent, first_line_column \\ nil) do
    for {:tag, site} <- found(text, first_line_and_indent, first_line_column), do: site
  end

  @doc """
  Scans `text` for interpolations, returning the body of each in document order.

  The position arguments are `tag_sites/3`'s. `line` and `column` are the file position of
  the body's first character, and `text` is the body with each continuation line prefixed
  by `indent` spaces, so a parse of `text` started at that position reads the file's own
  coordinates on every line.
  """
  @spec interpolations(String.t(), {pos_integer(), non_neg_integer()}) :: [interpolation()]
  @spec interpolations(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [
          interpolation()
        ]
  def interpolations(text, first_line_and_indent, first_line_column \\ nil) do
    for {:interpolation, body} <- found(text, first_line_and_indent, first_line_column), do: body
  end

  # One pass finds both kinds, so a tag and an interpolation can never disagree about what
  # the text between them is.
  defp found(text, {first_line, indent}, first_line_column)
       when is_binary(text) and is_integer(first_line) and is_integer(indent) do
    state = %{line: first_line, column: first_line_column || indent + 1, indent: indent}

    text
    |> scan(state, [])
    |> Enum.reverse()
  end

  defp scan(<<>>, _state, found), do: found

  defp scan(<<"\r\n", rest::binary>>, state, found), do: scan(rest, newline(state), found)
  defp scan(<<"\n", rest::binary>>, state, found), do: scan(rest, newline(state), found)

  defp scan(<<"<%!--", rest::binary>>, state, found) do
    {rest, state} = skip_past(rest, advance(state, 5), "--%>")
    scan(rest, state, found)
  end

  defp scan(<<"<!--", rest::binary>>, state, found) do
    {rest, state} = skip_past(rest, advance(state, 4), "-->")
    scan(rest, state, found)
  end

  defp scan(<<"<%=", rest::binary>> = binary, state, found),
    do: expression(binary, rest, state, found, 3)

  defp scan(<<"<%", rest::binary>> = binary, state, found),
    do: expression(binary, rest, state, found, 2)

  defp scan(<<"{", rest::binary>>, state, found) do
    body = advance(state, 1)

    case read_braces(rest, body, 1, false, []) do
      {rest, state, text, true} -> scan(rest, state, [collect(body, text) | found])
      {rest, state, _text, false} -> scan(rest, state, found)
    end
  end

  defp scan(<<"<script", rest::binary>>, state, found) when raw_boundary(rest) do
    {rest, state} = skip_past(rest, advance(state, 7), "</script>")
    scan(rest, state, found)
  end

  defp scan(<<"<style", rest::binary>>, state, found) when raw_boundary(rest) do
    {rest, state} = skip_past(rest, advance(state, 6), "</style>")
    scan(rest, state, found)
  end

  defp scan(<<"<", rest::binary>>, state, found) do
    case tag_site(rest, state) do
      nil ->
        scan(rest, advance(state, 1), found)

      {site, size} ->
        <<_name::binary-size(^size), after_name::binary>> = rest
        scan(after_name, advance(state, size + 1), [{:tag, site} | found])
    end
  end

  defp scan(<<_::utf8, rest::binary>>, state, found), do: scan(rest, advance(state, 1), found)
  defp scan(<<_, rest::binary>>, state, found), do: scan(rest, advance(state, 1), found)

  # A tag whose `%>` never arrives is no body at all, and the scan takes it as the two
  # characters it read, so the markup after it is still scanned for tags.
  defp expression(binary, rest, state, found, delimiter_size) do
    body = advance(state, delimiter_size)

    case read_until(rest, body, "%>", []) do
      {rest, state, text, true} ->
        scan(rest, state, [collect(body, text) | found])

      {_rest, _state, _text, false} ->
        <<_delimiter::binary-size(2), unread::binary>> = binary
        scan(unread, advance(state, 2), found)
    end
  end

  defp collect(body, text) do
    interpolation = %{
      line: body.line,
      column: body.column,
      text: text |> Enum.reverse() |> IO.iodata_to_binary()
    }

    {:interpolation, interpolation}
  end

  # Returns the site and the byte size of the name it matched, so the scan resumes past the
  # name rather than inside it.
  defp tag_site(binary, state) do
    case Regex.run(@tag, binary) do
      [matched, prefix, name] ->
        opening = state.column
        start = opening + 1
        name_column = start + String.length(prefix)
        column = if prefix == ".", do: opening, else: name_column

        site = %{
          line: state.line,
          column: column,
          range: %{
            start: {state.line, start},
            end: {state.line, name_column + String.length(name)}
          },
          template: nil,
          callee: nil
        }

        {site, byte_size(matched)}

      nil ->
        nil
    end
  end

  defp skip_past(<<>>, state, _marker), do: {<<>>, state}

  defp skip_past(binary, state, marker) do
    size = byte_size(marker)

    case binary do
      <<^marker::binary-size(^size), rest::binary>> ->
        {rest, advance(state, size)}

      <<"\r\n", rest::binary>> ->
        skip_past(rest, newline(state), marker)

      <<"\n", rest::binary>> ->
        skip_past(rest, newline(state), marker)

      <<_::utf8, rest::binary>> ->
        skip_past(rest, advance(state, 1), marker)

      <<_, rest::binary>> ->
        skip_past(rest, advance(state, 1), marker)
    end
  end

  # The body of an expression tag: everything up to `marker`, which is consumed.
  defp read_until(<<>>, state, _marker, text), do: {<<>>, state, text, false}

  defp read_until(binary, state, marker, text) do
    size = byte_size(marker)

    case binary do
      <<^marker::binary-size(^size), rest::binary>> ->
        {rest, advance(state, size), text, true}

      <<"\r\n", rest::binary>> ->
        read_until(rest, newline(state), marker, [break(state, "\r\n") | text])

      <<"\n", rest::binary>> ->
        read_until(rest, newline(state), marker, [break(state, "\n") | text])

      <<character::utf8, rest::binary>> ->
        read_until(rest, advance(state, 1), marker, [<<character::utf8>> | text])

      <<byte, rest::binary>> ->
        read_until(rest, advance(state, 1), marker, [<<byte>> | text])
    end
  end

  # The body of a `{...}`: everything up to the brace that closes the one already opened.
  # `string?` is whether the scan is inside a double-quoted string, where a brace is text.
  defp read_braces(<<>>, state, _depth, _string?, text), do: {<<>>, state, text, false}

  defp read_braces(<<"\\", character::utf8, rest::binary>>, state, depth, true, text)
       when character != ?\n,
       do: read_braces(rest, advance(state, 2), depth, true, [<<?\\, character::utf8>> | text])

  defp read_braces(<<"\"", rest::binary>>, state, depth, string?, text),
    do: read_braces(rest, advance(state, 1), depth, not string?, ["\"" | text])

  defp read_braces(<<"}", rest::binary>>, state, 1, false, text),
    do: {rest, advance(state, 1), text, true}

  defp read_braces(<<"}", rest::binary>>, state, depth, false, text),
    do: read_braces(rest, advance(state, 1), depth - 1, false, ["}" | text])

  defp read_braces(<<"{", rest::binary>>, state, depth, false, text),
    do: read_braces(rest, advance(state, 1), depth + 1, false, ["{" | text])

  defp read_braces(<<"\r\n", rest::binary>>, state, depth, string?, text),
    do: read_braces(rest, newline(state), depth, string?, [break(state, "\r\n") | text])

  defp read_braces(<<"\n", rest::binary>>, state, depth, string?, text),
    do: read_braces(rest, newline(state), depth, string?, [break(state, "\n") | text])

  defp read_braces(<<character::utf8, rest::binary>>, state, depth, string?, text),
    do: read_braces(rest, advance(state, 1), depth, string?, [<<character::utf8>> | text])

  defp read_braces(<<byte, rest::binary>>, state, depth, string?, text),
    do: read_braces(rest, advance(state, 1), depth, string?, [<<byte>> | text])

  # A heredoc reaches this module with its indentation stripped, so a continuation line of
  # a body opens `indent` columns to the left of where the file has it; writing the spaces
  # back puts a parse of the body on the file's own columns.
  defp break(state, newline), do: [newline, String.duplicate(" ", state.indent)]

  defp newline(state), do: %{state | line: state.line + 1, column: state.indent + 1}
  defp advance(state, count), do: %{state | column: state.column + count}
end
