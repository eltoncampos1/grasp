defmodule Grasp.Index.HeexTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Heex

  # A heredoc body as the compiler sees it: the sigil's indentation is already stripped,
  # so the caller maps it back with {first_line, indent}.
  @template """
  <div>
    <.badge label="x" />
    <SampleAppWeb.GreetingComponent.render name="n" />
    <:inner>a slot, not a component</:inner>
    <%!-- <.hidden /> --%>
    <!-- <.commented /> -->
    <span>{if @x, do: "<.nope />"}</span>
  </div>
  """

  test "reports a local tag at the opening angle bracket and a remote one at the function name" do
    assert Heex.tag_sites(@template, {10, 4}) == [
             %{
               line: 11,
               column: 7,
               range: %{start: {11, 8}, end: {11, 14}},
               template: nil,
               callee: nil
             },
             %{
               line: 12,
               column: 39,
               range: %{start: {12, 8}, end: {12, 45}},
               template: nil,
               callee: nil
             }
           ]
  end

  test "reads script and style bodies as raw text, where a brace opens no interpolation" do
    template = """
    <script>const brace = "{";</script>
    <.badge label="x" />
    <style>.a { color: red }</style>
    <.footer />
    """

    assert Heex.tag_sites(template, {1, 0}) |> Enum.map(& &1.line) == [2, 4]
  end

  test "reads an element whose name only starts with a raw one as an ordinary tag" do
    assert Heex.tag_sites("<scriptish>\n<.badge />\n", {1, 0}) |> Enum.map(& &1.line) == [2]
  end

  test "does not read a `<` inside an attribute value as a tag" do
    template = "<.badge label=\"a < b\" />\n<.footer />\n"

    assert Heex.tag_sites(template, {1, 0}) == [
             %{
               line: 1,
               column: 1,
               range: %{start: {1, 2}, end: {1, 8}},
               template: nil,
               callee: nil
             },
             %{
               line: 2,
               column: 1,
               range: %{start: {2, 2}, end: {2, 9}},
               template: nil,
               callee: nil
             }
           ]
  end

  test "reports a tag whose name runs to the end of the text" do
    assert Heex.tag_sites("<.badge", {1, 0}) == [
             %{
               line: 1,
               column: 1,
               range: %{start: {1, 2}, end: {1, 8}},
               template: nil,
               callee: nil
             }
           ]
  end

  test "places a template that starts mid-line from the column of its first character" do
    assert Heex.tag_sites("<.tiny />", {7, 0}, 12) == [
             %{
               line: 7,
               column: 12,
               range: %{start: {7, 13}, end: {7, 18}},
               template: nil,
               callee: nil
             }
           ]
  end

  test "carries the indent to every line of a multi-line tag and to nested tags" do
    template = """
    <.wrapper>
      <Acme.Card.header
        title="t"
      />
    </.wrapper>
    """

    assert Heex.tag_sites(template, {1, 2}) == [
             %{
               line: 1,
               column: 3,
               range: %{start: {1, 4}, end: {1, 12}},
               template: nil,
               callee: nil
             },
             %{
               line: 2,
               column: 16,
               range: %{start: {2, 6}, end: {2, 22}},
               template: nil,
               callee: nil
             }
           ]
  end

  test "reports nothing for a template without component tags" do
    assert Heex.tag_sites("<div class=\"a\">{@name}</div>\n", {1, 0}) == []
  end

  test "yields the body of a tag-body interpolation at the file position of its first character" do
    assert Heex.interpolations("<p>{Greeter.greet(@name)}</p>", {1, 0}) == [
             %{line: 1, column: 5, text: "Greeter.greet(@name)"}
           ]
  end

  test "yields the body of an attribute interpolation" do
    assert Heex.interpolations("<a class={cls(@x)} href=\"/\">", {1, 0}) == [
             %{line: 1, column: 11, text: "cls(@x)"}
           ]
  end

  test "yields the body of an expression tag, spaces and all, after its opening delimiter" do
    assert Heex.interpolations("<div>\n<%= if ok?(@u) do %>\n", {1, 4}) == [
             %{line: 2, column: 8, text: " if ok?(@u) do "}
           ]
  end

  test "re-indents a body that spans lines so a parse reads file columns on every line" do
    assert Heex.interpolations("{f(\n  @x)}\n", {1, 4}) == [
             %{line: 1, column: 6, text: "f(\n      @x)"}
           ]
  end

  test "yields nothing from a comment or a raw-text body" do
    assert Heex.interpolations("<%!-- {x} --%>\n", {1, 0}) == []
    assert Heex.interpolations("<script>{x}</script>\n", {1, 0}) == []
  end

  test "yields nothing for a brace the depth count never closes" do
    assert Heex.interpolations("{\"{\"}<p>{ok()}</p>", {1, 0}) == []
  end

  test "yields every interpolation on a line in document order" do
    assert Heex.interpolations("{a}{b}", {1, 0}) == [
             %{line: 1, column: 2, text: "a"},
             %{line: 1, column: 5, text: "b"}
           ]
  end

  test "reads a brace inside an expression tag as part of that tag" do
    assert Heex.interpolations("<%= %{a: 1} %>", {1, 0}) == [
             %{line: 1, column: 4, text: " %{a: 1} "}
           ]
  end

  test "yields nothing for an unterminated expression tag" do
    assert Heex.interpolations("<%= ok?(@u)", {1, 0}) == []
  end
end
