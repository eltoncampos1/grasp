defmodule Grasp.Index.Heex do
  @moduledoc """
  Finds the component tags in HEEx template text and reports each one at the position the
  compiler reports for the call it becomes.

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

  Four kinds of text are skipped, because none of them compiles to a component call:
  slot tags (`<:inner>`, which are not components), `<%!-- --%>` and `<!-- -->` comments,
  `{...}` interpolation, and the body of a `<script>` or `<style>` element, which HEEx
  treats as raw text where a brace is a brace and a `<` opens nothing.

  Interpolation is skipped by counting brace depth, not by parsing Elixir: a brace inside a
  string inside an interpolation (`{"{"}`) is counted like any other, so an unbalanced one
  swallows the rest of the template, as an unterminated `<%!--`, `<!--`, `<script>` or
  `<style>` does. EEx expression tags (`<%= ... %>`) are not skipped, so a tag written
  inside a string in one is reported, and so is a tag-shaped pattern inside a plain
  attribute string (`title="<.badge />"`) — harmless in both cases, since the compiler
  reports no call there and nothing lands on the site.
  """

  alias Grasp.Index.Extract

  @type site :: Extract.call_site()

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
  def tag_sites(text, first_line_and_indent, first_line_column \\ nil)

  def tag_sites(text, {first_line, indent}, first_line_column)
      when is_binary(text) and is_integer(first_line) and is_integer(indent) do
    state = %{line: first_line, column: first_line_column || indent + 1, indent: indent}

    text
    |> scan(state, [])
    |> Enum.reverse()
  end

  defp scan(<<>>, _state, sites), do: sites

  defp scan(<<"\r\n", rest::binary>>, state, sites), do: scan(rest, newline(state), sites)
  defp scan(<<"\n", rest::binary>>, state, sites), do: scan(rest, newline(state), sites)

  defp scan(<<"<%!--", rest::binary>>, state, sites) do
    {rest, state} = skip_past(rest, advance(state, 5), "--%>")
    scan(rest, state, sites)
  end

  defp scan(<<"<!--", rest::binary>>, state, sites) do
    {rest, state} = skip_past(rest, advance(state, 4), "-->")
    scan(rest, state, sites)
  end

  defp scan(<<"{", rest::binary>>, state, sites) do
    {rest, state} = skip_braces(rest, advance(state, 1), 1)
    scan(rest, state, sites)
  end

  defp scan(<<"<script", rest::binary>>, state, sites) when raw_boundary(rest) do
    {rest, state} = skip_past(rest, advance(state, 7), "</script>")
    scan(rest, state, sites)
  end

  defp scan(<<"<style", rest::binary>>, state, sites) when raw_boundary(rest) do
    {rest, state} = skip_past(rest, advance(state, 6), "</style>")
    scan(rest, state, sites)
  end

  defp scan(<<"<", rest::binary>>, state, sites) do
    case tag_site(rest, state) do
      nil ->
        scan(rest, advance(state, 1), sites)

      {site, size} ->
        <<_name::binary-size(^size), after_name::binary>> = rest
        scan(after_name, advance(state, size + 1), [site | sites])
    end
  end

  defp scan(<<_::utf8, rest::binary>>, state, sites), do: scan(rest, advance(state, 1), sites)
  defp scan(<<_, rest::binary>>, state, sites), do: scan(rest, advance(state, 1), sites)

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
          template: nil
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

  defp skip_braces(<<>>, state, _depth), do: {<<>>, state}
  defp skip_braces(binary, state, 0), do: {binary, state}

  defp skip_braces(<<"\r\n", rest::binary>>, state, depth),
    do: skip_braces(rest, newline(state), depth)

  defp skip_braces(<<"\n", rest::binary>>, state, depth),
    do: skip_braces(rest, newline(state), depth)

  defp skip_braces(<<"{", rest::binary>>, state, depth),
    do: skip_braces(rest, advance(state, 1), depth + 1)

  defp skip_braces(<<"}", rest::binary>>, state, depth),
    do: skip_braces(rest, advance(state, 1), depth - 1)

  defp skip_braces(<<_::utf8, rest::binary>>, state, depth),
    do: skip_braces(rest, advance(state, 1), depth)

  defp skip_braces(<<_, rest::binary>>, state, depth),
    do: skip_braces(rest, advance(state, 1), depth)

  defp newline(state), do: %{state | line: state.line + 1, column: state.indent + 1}
  defp advance(state, count), do: %{state | column: state.column + count}
end
