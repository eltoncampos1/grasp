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

  The same pass reads a tag's attributes. After the name of an element — a component tag,
  an ordinary `<div>`, a slot — the scan reads attribute after attribute until the `>` or
  `/>` that ends the tag: a name, and where one follows the `=`, a value in double quotes,
  single quotes, braces or none at all. A `{...}` written as an attribute's whole value
  (`attr={...}`) is an interpolation and is yielded as one, and so is a nameless `{...}`
  root attribute (`<div {@rest}>`); braces inside a quoted value are text, which is what
  HEEx makes of them. What `route_attributes/2,3` returns of all that is the attributes
  that name a route — `href`, `action`, `navigate`, `patch` and the `hx-*` verbs — each
  carrying the tag it was written on, its value as a string or an interpolation, the tag's
  literal `method` where it has one, and the range of the value with its delimiters, which
  is what a reader clicks. A tag whose `>` never arrives, or that a second `<` interrupts, yields no
  attribute at all: the scan resumes at that `<`, where the markup makes sense again.

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
  map in `<%= %{a: 1} %>` belongs to the tag; a tag-shaped pattern inside a quoted
  attribute value (`title="<.badge />"`) is reported as nothing at all, because the value
  is read as the text it is.
  """

  alias Grasp.Index.Extract

  @type site :: Extract.call_site()
  @type interpolation :: %{line: pos_integer(), column: pos_integer(), text: String.t()}
  @type attribute_value :: {:string, String.t()} | {:expr, interpolation()}
  @type route_attribute :: %{
          tag: String.t(),
          name: String.t(),
          method: String.t() | nil,
          value: attribute_value(),
          range: Extract.range()
        }

  # A local tag (`.name`) or a remote one (`Alias.Path.name`) directly after the `<`. The
  # lookahead keeps the match off names the HEEx tokenizer would read as one longer name.
  @tag ~r/\A(\.|(?:[A-Z]\w*\.)+)([a-z_]\w*[?!]?)(?![\w.\-?!])/

  # Any element name, so the attributes of a `<div>` are read like a component's.
  @element ~r/\A[A-Za-z.:][\w.:\-]*/
  @attribute ~r/\A[^\s=\/>{}"']+/
  # An unquoted value runs to the whitespace or `>` that ends it, and stops short of the
  # `/` of a `/>`, which closes the tag rather than belonging to the value.
  @unquoted ~r/\A(?:[^\s>\/]|\/(?!>))+/

  # The attributes whose value is a path the router answers to.
  @route_attributes ~w(href action navigate patch hx-get hx-post hx-put hx-patch hx-delete)

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

  @doc """
  Scans `text` for the attributes that name a route, in document order.

  The position arguments are `tag_sites/3`'s. An attribute is reported once the tag it
  belongs to is closed, with the `method` that tag wrote beside it, so a `<form>` and a
  `<.form>` can be told apart from the verb they mean. `range` covers the value and its
  delimiters, from the opening `"`, `'` or `{` to one past the closing one.
  """
  @spec route_attributes(String.t(), {pos_integer(), non_neg_integer()}) :: [route_attribute()]
  @spec route_attributes(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [
          route_attribute()
        ]
  def route_attributes(text, first_line_and_indent, first_line_column \\ nil) do
    for {:route_attribute, attribute} <-
          found(text, first_line_and_indent, first_line_column),
        do: attribute
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
        case Regex.run(@element, rest) do
          [name] -> element(rest, state, found, name)
          nil -> scan(rest, advance(state, 1), found)
        end

      {site, size} ->
        <<name::binary-size(^size), _after_name::binary>> = rest
        element(rest, state, [{:tag, site} | found], name)
    end
  end

  defp scan(<<_::utf8, rest::binary>>, state, found), do: scan(rest, advance(state, 1), found)
  defp scan(<<_, rest::binary>>, state, found), do: scan(rest, advance(state, 1), found)

  defp element(binary, state, found, name) do
    size = byte_size(name)
    <<_name::binary-size(^size), rest::binary>> = binary
    attributes(rest, advance(state, size + 1), found, name, [])
  end

  # Attribute mode: everything between an element's name and the `>` that ends it. The
  # attributes read so far are held until then, because the `method` one of them writes
  # decides what verb another of them means. A tag that never closes hands back none of
  # them; the interpolations it held are already found, since a `{...}` is Elixir wherever
  # the markup around it goes wrong.
  defp attributes(<<>>, _state, found, _tag, _written), do: found

  defp attributes(<<"/>", rest::binary>>, state, found, tag, written),
    do: scan(rest, advance(state, 2), tag_route_attributes(tag, written) ++ found)

  defp attributes(<<">", rest::binary>>, state, found, tag, written),
    do: scan(rest, advance(state, 1), tag_route_attributes(tag, written) ++ found)

  defp attributes(<<"\r\n", rest::binary>>, state, found, tag, written),
    do: attributes(rest, newline(state), found, tag, written)

  defp attributes(<<"\n", rest::binary>>, state, found, tag, written),
    do: attributes(rest, newline(state), found, tag, written)

  defp attributes(<<space, rest::binary>>, state, found, tag, written)
       when space in [?\s, ?\t, ?\r],
       do: attributes(rest, advance(state, 1), found, tag, written)

  defp attributes(<<"<", _rest::binary>> = binary, state, found, _tag, _written),
    do: scan(binary, state, found)

  defp attributes(<<"{", rest::binary>>, state, found, tag, written) do
    case root_attribute(rest, state) do
      {rest, state, interpolation} ->
        attributes(rest, state, [interpolation | found], tag, written)

      {rest, state} ->
        attributes(rest, state, found, tag, written)
    end
  end

  defp attributes(binary, state, found, tag, written) do
    case Regex.run(@attribute, binary) do
      [name] ->
        size = byte_size(name)
        <<_name::binary-size(^size), rest::binary>> = binary
        assignment(rest, advance(state, String.length(name)), found, tag, written, name)

      nil ->
        skip_one(binary, state, found, tag, written)
    end
  end

  defp skip_one(<<_::utf8, rest::binary>>, state, found, tag, written),
    do: attributes(rest, advance(state, 1), found, tag, written)

  defp skip_one(<<_, rest::binary>>, state, found, tag, written),
    do: attributes(rest, advance(state, 1), found, tag, written)

  defp assignment(<<"=", rest::binary>>, state, found, tag, written, name),
    do: value(rest, advance(state, 1), found, tag, written, name)

  # An attribute with no value (`disabled`) names no route and carries no Elixir.
  defp assignment(binary, state, found, tag, written, _name),
    do: attributes(binary, state, found, tag, written)

  defp value(<<quote_mark, rest::binary>>, state, found, tag, written, name)
       when quote_mark in [?", ?'] do
    body = advance(state, 1)

    case read_until(rest, body, <<quote_mark>>, []) do
      {rest, closed, text, true} ->
        string = text |> Enum.reverse() |> IO.iodata_to_binary()
        attribute = {name, {:string, string}, span(state, closed)}
        attributes(rest, closed, found, tag, [attribute | written])

      {rest, unclosed, _text, false} ->
        attributes(rest, unclosed, found, tag, written)
    end
  end

  defp value(<<"{", rest::binary>>, state, found, tag, written, name) do
    body = advance(state, 1)

    case read_braces(rest, body, 1, false, []) do
      {rest, closed, text, true} ->
        {:interpolation, interpolation} = collect(body, text)
        attribute = {name, {:expr, interpolation}, span(state, closed)}

        attributes(rest, closed, [{:interpolation, interpolation} | found], tag, [
          attribute | written
        ])

      {rest, unclosed, _text, false} ->
        attributes(rest, unclosed, found, tag, written)
    end
  end

  defp value(binary, state, found, tag, written, name) do
    case Regex.run(@unquoted, binary) do
      [text] ->
        size = byte_size(text)
        <<_text::binary-size(^size), rest::binary>> = binary
        read = advance(state, String.length(text))
        attribute = {name, {:string, text}, span(state, read)}
        attributes(rest, read, found, tag, [attribute | written])

      nil ->
        attributes(binary, state, found, tag, written)
    end
  end

  defp root_attribute(binary, state) do
    body = advance(state, 1)

    case read_braces(binary, body, 1, false, []) do
      {rest, closed, text, true} -> {rest, closed, collect(body, text)}
      {rest, unclosed, _text, false} -> {rest, unclosed}
    end
  end

  # Document order: the tag's attributes are held in reverse, and `found` is reversed once
  # the whole scan is done, so the list this prepends is reversed twice and comes back the
  # way the tag wrote it.
  defp tag_route_attributes(tag, written) do
    method =
      Enum.find_value(written, fn
        {"method", {:string, value}, _range} -> String.upcase(value)
        _attribute -> nil
      end)

    for {name, value, range} <- written, name in @route_attributes do
      {:route_attribute, %{tag: tag, name: name, method: method, value: value, range: range}}
    end
  end

  defp span(opening, closing),
    do: %{start: {opening.line, opening.column}, end: {closing.line, closing.column}}

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
