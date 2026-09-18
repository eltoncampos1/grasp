defmodule Grasp.Index.TemplatesTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Templates

  @template """
  <.badge label="hi" />
  <SampleAppWeb.GreetingComponent.render name={@name} />
  """

  @tag :tmp_dir
  test "builds a definition per template the pattern matches", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")
    write!(root, "lib/sample_app_web/greet_html/show.html.heex", @template)
    write!(root, "lib/sample_app_web/greet_html/edit.html.heex", "<p>edit</p>\n")
    write!(root, "lib/sample_app_web/greet_html/README.md", "not a template\n")

    assert [edit, show] = Templates.definitions(root, [embed()], [])

    assert %{
             module: "SampleAppWeb.GreetHTML",
             name: :show,
             arity: 1,
             arities: [1],
             kind: :template,
             file: "lib/sample_app_web/greet_html/show.html.heex",
             start_line: 1,
             end_line: 2,
             source: @template,
             head_positions: [],
             head_ranges: []
           } = show

    assert Enum.map(show.call_sites, & &1.range) == [
             %{start: {1, 2}, end: {1, 8}},
             %{start: {2, 2}, end: {2, 39}}
           ]

    assert %{name: :edit, end_line: 1, call_sites: []} = edit
  end

  @tag :tmp_dir
  test "leaves a function the module writes by hand to its own definition", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")
    write!(root, "lib/sample_app_web/greet_html/show.html.heex", @template)

    written = [%{module: "SampleAppWeb.GreetHTML", name: :show, arity: 1}]

    assert Templates.definitions(root, [embed()], written) == []
  end

  defp embed do
    %{
      module: "SampleAppWeb.GreetHTML",
      pattern: "greet_html/*",
      file: "lib/sample_app_web/greet_html.ex",
      line: 2
    }
  end

  defp write!(root, path, contents) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
