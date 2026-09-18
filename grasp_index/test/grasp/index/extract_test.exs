defmodule Grasp.Index.ExtractTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Extract

  @source ~S"""
  defmodule Sample do
    # Says hi.
    @doc "Greets."
    @spec greet(String.t(), boolean()) :: String.t()
    def greet(name, loud? \\ false) do
      text = Formatter.wrap(name)
      if loud?, do: shout(text), else: text
    end

    def count(list) when is_list(list), do: length(list)
    def count(_), do: 0

    defmodule Nested do
      def hello, do: Sample.greet("n")
    end

    defmodule __MODULE__.Deep do
      defp hidden, do: :ok
    end
  end
  """

  test "groups clauses and attaches doc, spec and leading comments to the span" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    greet = find(defs, "Sample", :greet)
    assert %{arity: 2, arities: [1, 2], kind: :def, file: "lib/sample.ex"} = greet
    assert greet.start_line == 2
    assert greet.end_line == 8
    assert greet.source == @source |> String.split("\n") |> Enum.slice(1, 7) |> Enum.join("\n")

    count = find(defs, "Sample", :count)
    assert %{arity: 1, arities: [1], start_line: 10, end_line: 11} = count
    assert String.starts_with?(count.source, "  def count(list) when")
    assert String.ends_with?(count.source, "def count(_), do: 0")
  end

  test "resolves nested and __MODULE__-prefixed module names" do
    {:ok, %{definitions: defs, modules: modules}} = Extract.extract(@source, "lib/sample.ex")

    assert %{kind: :def, start_line: 14, end_line: 14} = find(defs, "Sample.Nested", :hello)
    assert %{kind: :defp} = find(defs, "Sample.Deep", :hidden)

    assert modules == [
             %{name: "Sample", file: "lib/sample.ex", line: 1},
             %{name: "Sample.Nested", file: "lib/sample.ex", line: 13},
             %{name: "Sample.Deep", file: "lib/sample.ex", line: 17}
           ]
  end

  test "collects call sites keyed by the function name position, ranging over the callee only" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    greet = find(defs, "Sample", :greet)

    assert %{range: %{start: {6, 12}, end: {6, 26}}} = site(greet, 6, 22)
    assert %{range: %{start: {7, 19}, end: {7, 24}}} = site(greet, 7, 19)

    count = find(defs, "Sample", :count)
    assert %{range: %{start: {10, 24}, end: {10, 31}}} = site(count, 10, 24)
  end

  @kinds ~S"""
  defmodule Ops do
    defdelegate size(x), to: Enum, as: :count
    defguard is_pos(x) when x > 0
    def zero, do: 0
    def all(list), do: Enum.map(list, &double/1)
    defp double(x), do: x * 2
    defmacro twice(x), do: quote(do: unquote(x) * 2)
  end
  """

  test "recognises every definition kind and parenless heads" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")

    assert %{kind: :defdelegate, arity: 1} = find(defs, "Ops", :size)
    assert %{kind: :defguard, arity: 1} = find(defs, "Ops", :is_pos)
    assert %{kind: :def, arity: 0, arities: [0]} = find(defs, "Ops", :zero)
    assert %{kind: :defp} = find(defs, "Ops", :double)
    assert %{kind: :defmacro} = find(defs, "Ops", :twice)
  end

  test "treats function captures as call sites" do
    {:ok, %{definitions: defs}} = Extract.extract(@kinds, "lib/ops.ex")
    all = find(defs, "Ops", :all)

    assert %{range: %{start: {5, 22}, end: {5, 30}}} = site(all, 5, 27)
    assert %{range: %{start: {5, 38}, end: {5, 44}}} = site(all, 5, 38)
  end

  test "returns the parser error for invalid source" do
    assert {:error, _} = Extract.extract("defmodule Broken do\n  def (\nend\n", "lib/broken.ex")
  end

  test "records the head position and range of every clause" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    greet = find(defs, "Sample", :greet)
    assert greet.head_positions == [{5, 7}]
    assert greet.head_ranges == [%{start: {5, 7}, end: {5, 12}}]

    count = find(defs, "Sample", :count)
    assert count.head_positions == [{10, 7}, {11, 7}]
  end

  test "keeps the guard site and adds no site for the head or its operators" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")
    count = find(defs, "Sample", :count)

    assert %{range: %{start: {10, 24}, end: {10, 31}}} = site(count, 10, 24)
    refute site(count, 10, 7)
  end

  @defaults ~S"""
  defmodule Defaults do
    def greet(name, prefix \\ String.trim(" p ")) do
      prefix <> name
    end
  end
  """

  test "collects call sites inside default-argument expressions" do
    {:ok, %{definitions: defs}} = Extract.extract(@defaults, "lib/defaults.ex")
    greet = find(defs, "Defaults", :greet)

    assert %{range: %{start: {2, 29}, end: {2, 40}}} = site(greet, 2, 36)
    refute site(greet, 2, 7)
  end

  test "produces no site for special forms the compiler never reports" do
    source = ~S"""
    defmodule Forms do
      def build(map, bin, list) do
        %{a: a} = map
        <<b::binary>> = bin
        [h | t] = list
        ^a = h
        {%Range{first: a}, b, t}
      end
    end
    """

    {:ok, %{definitions: defs}} = Extract.extract(source, "lib/forms.ex")
    assert find(defs, "Forms", :build).call_sites == []
  end

  @templates ~S'''
  defmodule SampleWeb.Page do
    embed_templates "page_html/*"

    def render(assigns) do
      ~H"""
      <.badge label="x" />
      <SampleAppWeb.GreetingComponent.render name={@name} />
      """
    end

    def show(conn, name) do
      render(conn, :show, name: name)
    end

    def legacy(conn), do: render(conn, "show.html", [])
  end
  '''

  test "turns the component tags of a ~H sigil into call sites with file coordinates" do
    {:ok, %{definitions: defs}} = Extract.extract(@templates, "lib/sample_web/page.ex")
    render = find(defs, "SampleWeb.Page", :render)

    assert %{range: %{start: {6, 6}, end: {6, 12}}, template: nil} = site(render, 6, 5)
    assert %{range: %{start: {7, 6}, end: {7, 43}}, template: nil} = site(render, 7, 37)
  end

  @inline_template ~S'''
  defmodule SampleWeb.Inline do
    def badge(assigns), do: ~H"<.label text={@text} />"
  end
  '''

  test "keys a single-line ~H sigil's tags where the compiler reports them, ranged where written" do
    {:ok, %{definitions: defs}} = Extract.extract(@inline_template, "lib/sample_web/inline.ex")
    badge = find(defs, "SampleWeb.Inline", :badge)

    assert site(badge, 3, 1) == %{
             line: 3,
             column: 1,
             range: %{start: {2, 31}, end: {2, 37}},
             template: nil
           }
  end

  test "names the template a render call renders, dropping the .html suffix" do
    {:ok, %{definitions: defs}} = Extract.extract(@templates, "lib/sample_web/page.ex")

    assert %{template: "show"} = site(find(defs, "SampleWeb.Page", :show), 12, 5)
    assert %{template: "show"} = site(find(defs, "SampleWeb.Page", :legacy), 15, 25)
  end

  test "collects the template patterns a module embeds" do
    {:ok, %{embeds: embeds}} = Extract.extract(@templates, "lib/sample_web/page.ex")

    assert embeds == [
             %{
               module: "SampleWeb.Page",
               pattern: "page_html/*",
               file: "lib/sample_web/page.ex",
               line: 2
             }
           ]
  end

  test "leaves template nil on a call site that is not a render call" do
    {:ok, %{definitions: defs}} = Extract.extract(@source, "lib/sample.ex")

    assert %{template: nil} = site(find(defs, "Sample", :greet), 6, 22)
  end

  defp find(defs, module, name), do: Enum.find(defs, &(&1.module == module and &1.name == name))

  defp site(def, line, column),
    do: Enum.find(def.call_sites, &(&1.line == line and &1.column == column))
end
