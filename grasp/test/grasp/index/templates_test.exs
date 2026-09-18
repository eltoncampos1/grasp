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
    write!(root, "lib/sample_app_web/greet_html/legacy.html.eex", @template)
    write!(root, "lib/sample_app_web/greet_html/README.md", "not a template\n")

    assert [edit, legacy, show] = Templates.definitions(root, [embed()], [])

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

    # An EEx template is a record like any other, but its tags are markup rather than
    # component calls, so it carries no sites even when it reads like a HEEx one.
    assert %{
             name: :legacy,
             kind: :template,
             file: "lib/sample_app_web/greet_html/legacy.html.eex",
             call_sites: []
           } = legacy
  end

  @tag :tmp_dir
  test "leaves a function the module writes by hand to its own definition", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")
    write!(root, "lib/sample_app_web/greet_html/show.html.heex", @template)

    # A component with a default argument is written under `show/2` and answers to `show/1`,
    # which is the arity the template would claim.
    written = [%{module: "SampleAppWeb.GreetHTML", name: :show, arity: 2, arities: [1, 2]}]

    assert Templates.definitions(root, [embed()], written) == []
  end

  @tag :tmp_dir
  test "names a template a pattern walks up to by the path the project uses", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")
    write!(root, "lib/shared_html/banner.html.heex", @template)

    embed = %{embed() | pattern: "../shared_html/*"}

    assert [%{name: :banner, file: "lib/shared_html/banner.html.heex"}] =
             Templates.definitions(root, [embed], [])
  end

  @tag :tmp_dir
  test "drops a template the pattern reaches outside the project", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")

    outside = Path.join(Path.dirname(root), "grasp-outside-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(outside) end)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "stray.html.heex"), @template)

    embed = %{embed() | pattern: "../../../#{Path.basename(outside)}/*"}

    assert [_stray] = Path.wildcard(Path.join(outside, "*.{heex,eex}"))
    assert Templates.definitions(root, [embed], []) == []
  end

  @tag :tmp_dir
  test "carries the suffix an embed names into the function it defines", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")
    write!(root, "lib/sample_app_web/greet_html/welcome.html.heex", @template)

    embed = %{embed() | suffix: "_html"}

    assert [%{name: :welcome_html, arity: 1}] = Templates.definitions(root, [embed], [])
  end

  @tag :tmp_dir
  test "globs under the root an embed names", %{tmp_dir: root} do
    write!(root, "lib/sample_app_web/greet_html.ex", "defmodule SampleAppWeb.GreetHTML do\nend\n")
    write!(root, "lib/shared/mail/welcome.html.heex", @template)

    embed = %{embed() | pattern: "mail/*", root: "../shared"}

    assert [%{name: :welcome, file: "lib/shared/mail/welcome.html.heex"}] =
             Templates.definitions(root, [embed], [])
  end

  defp embed do
    %{
      module: "SampleAppWeb.GreetHTML",
      pattern: "greet_html/*",
      suffix: nil,
      root: nil,
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
