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
               template: nil
             },
             %{
               line: 12,
               column: 39,
               range: %{start: {12, 8}, end: {12, 45}},
               template: nil
             }
           ]
  end

  test "skips slots, comments and interpolation" do
    sites = Heex.tag_sites(@template, {10, 4})

    assert Enum.map(sites, & &1.line) == [11, 12]
  end

  test "places a template that starts mid-line from the column of its first character" do
    assert Heex.tag_sites("<.tiny />", {7, 0}, 12) == [
             %{line: 7, column: 12, range: %{start: {7, 13}, end: {7, 18}}, template: nil}
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
             %{line: 1, column: 3, range: %{start: {1, 4}, end: {1, 12}}, template: nil},
             %{line: 2, column: 16, range: %{start: {2, 6}, end: {2, 22}}, template: nil}
           ]
  end

  test "reports nothing for a template without component tags" do
    assert Heex.tag_sites("<div class=\"a\">{@name}</div>\n", {1, 0}) == []
  end
end
