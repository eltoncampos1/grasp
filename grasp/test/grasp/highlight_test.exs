defmodule Grasp.HighlightTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Grasp.Highlight

  @record %{
    "id" => "Sample.run/1",
    "span" => %{"start_line" => 10, "end_line" => 12},
    "source" => "def run(x) do\n  Enum.map(x, &g/1)\n  <b>\nend",
    "calls" => [
      %{
        "target" => "Enum.map/2",
        "kind" => "remote",
        "range" => %{"start" => [11, 3], "end" => [11, 11]}
      },
      %{
        "target" => "Sample.g/1",
        "kind" => "local",
        "range" => %{"start" => [11, 16], "end" => [11, 17]}
      }
    ]
  }

  @fixture Path.expand("../fixtures/index.json", __DIR__)

  defp render(opts \\ []), do: render(@record, opts)

  defp render(record, opts) do
    record |> render_string(opts) |> LazyHTML.from_fragment()
  end

  defp render_string(record, opts) do
    opts = Keyword.merge([card_id: 7, open_calls: %{}, external?: fn _ -> false end], opts)
    record |> Highlight.render(opts) |> Phoenix.HTML.safe_to_string()
  end

  test "numbers lines from the span start and escapes source text" do
    html = render()
    assert LazyHTML.query(html, "span.line[data-line='10'] .ln") |> LazyHTML.text() == "10"
    assert LazyHTML.query(html, "span.line[data-line='12']") |> LazyHTML.text() =~ "<b>"
    assert LazyHTML.query(html, "span.line") |> Enum.count() == 4
  end

  test "wraps each call range in a clickable span covering exactly the callee" do
    html = render(open_calls: %{"Enum.map/2" => %{to: 2, color: 0}})
    [map] = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()

    assert LazyHTML.text(map) == "Enum.map"
    assert LazyHTML.attribute(map, "phx-click") == ["open_call"]
    assert LazyHTML.attribute(map, "phx-value-card") == ["7"]
    assert LazyHTML.attribute(map, "data-open") == ["true"]
    assert LazyHTML.query(map, "span.l-module") |> LazyHTML.text() == "Enum"

    [g] = LazyHTML.query(html, "span.call[data-target='Sample.g/1']") |> Enum.to_list()
    assert LazyHTML.text(g) == "g"
    assert LazyHTML.attribute(g, "data-open") == ["false"]
  end

  test "an open call carries the colour and the destination of the edge leaving it" do
    html = render(open_calls: %{"Enum.map/2" => %{to: 7, color: 3}})

    [map] = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()
    assert LazyHTML.attribute(map, "data-open") == ["true"]
    assert LazyHTML.attribute(map, "data-color") == ["3"]
    assert LazyHTML.attribute(map, "data-edge-to") == ["7"]

    [g] = LazyHTML.query(html, "span.call[data-target='Sample.g/1']") |> Enum.to_list()
    assert LazyHTML.attribute(g, "data-open") == ["false"]
    assert LazyHTML.attribute(g, "data-color") == []
    assert LazyHTML.attribute(g, "data-edge-to") == []
  end

  test "marks external targets" do
    html = render(external?: &(&1 == "Enum.map/2"))

    assert LazyHTML.query(html, "span.call[data-target='Enum.map/2']")
           |> LazyHTML.attribute("data-external") == ["true"]

    assert LazyHTML.query(html, "span.call[data-target='Sample.g/1']")
           |> LazyHTML.attribute("data-external") == ["false"]
  end

  test "nested Lumis spans keep the innermost class and exact columns" do
    record = %{
      "id" => "S.f/1",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => ~S|def f(x), do: "a #{inspect(x)} b"|,
      "calls" => [
        %{
          "target" => "Kernel.inspect/1",
          "kind" => "imported",
          "range" => %{"start" => [1, 20], "end" => [1, 27]}
        }
      ]
    }

    html =
      record
      |> Highlight.render(card_id: 1, open_calls: %{}, external?: fn _ -> false end)
      |> Phoenix.HTML.safe_to_string()
      |> LazyHTML.from_fragment()

    [call] = LazyHTML.query(html, "span.call[data-target='Kernel.inspect/1']") |> Enum.to_list()
    assert LazyHTML.text(call) == "inspect"
    assert LazyHTML.query(call, "span.l-function-call") |> LazyHTML.text() == "inspect"

    assert LazyHTML.query(html, "span.line[data-line='1']") |> LazyHTML.text() ==
             ~S|1def f(x), do: "a #{inspect(x)} b"|
  end

  test "a range spanning two lines produces one call span per line" do
    record = %{
      "id" => "S.spanning/0",
      "span" => %{"start_line" => 1, "end_line" => 3},
      "source" => "def f do\n  Enum\n  .map([], & &1)\nend",
      "calls" => [
        %{
          "target" => "Enum.map/2",
          "kind" => "remote",
          "range" => %{"start" => [2, 3], "end" => [3, 7]}
        }
      ]
    }

    html =
      record
      |> Highlight.render(card_id: 1, open_calls: %{}, external?: fn _ -> false end)
      |> Phoenix.HTML.safe_to_string()
      |> LazyHTML.from_fragment()

    spans = LazyHTML.query(html, "span.call[data-target='Enum.map/2']") |> Enum.to_list()
    assert Enum.map(spans, &LazyHTML.text/1) == ["Enum", ".map"]
  end

  test "a blank line inside the body keeps its number in the gutter" do
    record = %{
      "id" => "S.blank/0",
      "span" => %{"start_line" => 10, "end_line" => 14},
      "source" => "def f do\n  a = 1\n\n  a\nend",
      "calls" => []
    }

    html = render(record, [])

    assert LazyHTML.query(html, "span.line") |> Enum.count() == 5

    assert LazyHTML.query(html, "span.line") |> LazyHTML.attribute("data-line") ==
             ~w(10 11 12 13 14)

    assert LazyHTML.query(html, "span.line[data-line='12'] .ln") |> LazyHTML.text() == "12"
    assert LazyHTML.query(html, "span.line[data-line='12']") |> LazyHTML.text() == "12"
  end

  test "emits nothing between line spans, since a newline inside the <pre> would render as an empty line" do
    record = %{
      "id" => "S.tight/0",
      "span" => %{"start_line" => 1, "end_line" => 2},
      "source" => "def f do\nend",
      "calls" => []
    }

    refute render_string(record, []) =~ ~r{</span>\s+<span class="line"}
  end

  test "renders a real indexed record with the indexer's own columns" do
    {:ok, index} = Grasp.Index.load(@fixture)
    {:ok, record} = Grasp.Index.fetch_function(index, "SampleApp.Formatter.shout/1")

    html = render(record, [])

    assert LazyHTML.query(html, "span.call[data-target='String.upcase/1']") |> LazyHTML.text() ==
             "String.upcase"
  end

  test "a source Lumis cannot parse renders as unhighlighted text and says so once" do
    record = %{
      "id" => "S.unparseable/0",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => <<"def f, do: ", 0xFF, "()">>,
      "calls" => []
    }

    {html, log} = with_log(fn -> render(record, []) end)

    assert LazyHTML.query(html, "span.line") |> Enum.count() == 1
    assert LazyHTML.query(html, "span[class^='l-']") |> Enum.count() == 0
    assert log =~ "highlighting unavailable for S.unparseable/0"
  end

  test "escapes a target carrying markup in both attributes that hold it" do
    target = ~s(A."<b>"/1)

    record = %{
      "id" => "S.escaping/0",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => "def f, do: g()",
      "calls" => [
        %{
          "target" => target,
          "kind" => "local",
          "range" => %{"start" => [1, 12], "end" => [1, 13]}
        }
      ]
    }

    string = render_string(record, [])
    refute string =~ ~s(<b>)
    assert string =~ "&lt;b&gt;"
    assert string =~ "&quot;"

    call = string |> LazyHTML.from_fragment() |> LazyHTML.query("span.call")
    assert LazyHTML.attribute(call, "data-target") == [target]
    assert LazyHTML.attribute(call, "phx-value-target") == [target]
  end

  test "a highlighted call carries data-highlight and the others do not" do
    html = render(highlight: %{"call" => "Enum.map/2"})
    assert LazyHTML.query(html, ~s(.call[data-highlight="true"])) |> Enum.count() == 1

    assert LazyHTML.query(html, ~s(.call[data-highlight="true"]))
           |> LazyHTML.attribute("data-target") == ["Enum.map/2"]
  end

  test "highlighted lines carry data-highlight over the range only" do
    html = render(highlight: %{"lines" => [11, 12]})

    assert LazyHTML.query(html, ~s(.line[data-highlight="true"]))
           |> LazyHTML.attribute("data-line") == ~w(11 12)
  end

  test "no highlight, no attribute" do
    html = render()
    assert LazyHTML.query(html, "[data-highlight]") |> Enum.count() == 0
  end
end
