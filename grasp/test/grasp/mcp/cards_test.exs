defmodule Grasp.MCP.CardsTest do
  use ExUnit.Case, async: true

  alias Grasp.MCP.Cards

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"
  @hello_render "SampleAppWeb.HelloLive.render/1"

  setup_all do
    {:ok, index} = Grasp.Index.load("test/fixtures/index.json")
    %{index: index}
  end

  test "prepare resolves aliases and links children through the parent's call", %{index: index} do
    cards = [
      %{key: "root", function_id: @show, parent_key: nil, highlight: nil},
      %{
        key: "g",
        function_id: "SampleApp.Greeter.greet/1",
        parent_key: "root",
        highlight: %{call: @wrap, lines: nil}
      },
      %{key: "w", function_id: @wrap, parent_key: "g", highlight: %{call: nil, lines: [4, 5]}}
    ]

    assert {:ok, [root, g, w]} = Cards.prepare(index, cards)
    assert %{function_id: @show, parent_key: nil, opened_by: nil} = root

    # the controller calls greet/1; the card shows the canonical greet/2 but is linked by
    # the raw target
    assert %{
             function_id: @greet,
             parent_key: "root",
             opened_by: "SampleApp.Greeter.greet/1",
             highlight: %{"call" => @wrap}
           } = g

    assert %{function_id: @wrap, opened_by: @wrap, highlight: %{"lines" => [4, 5]}} = w
  end

  test "a hidden call links too", %{index: index} do
    cards = [
      %{key: "r", function_id: @hello_render, parent_key: nil, highlight: nil},
      %{key: "g", function_id: @greet, parent_key: "r", highlight: nil}
    ]

    assert {:ok, [_, %{opened_by: "SampleApp.Greeter.greet/1"}]} = Cards.prepare(index, cards)
  end

  test "an omitted parent_key and highlight read as a root marking nothing", %{index: index} do
    assert {:ok, [%{key: "root", parent_key: nil, opened_by: nil, highlight: nil}]} =
             Cards.prepare(index, [%{key: "root", function_id: @show}])
  end

  test "unknown functions and parents are one readable error", %{index: index} do
    cards = [
      %{key: "a", function_id: "Nope.f/0", parent_key: nil, highlight: nil},
      %{key: "b", function_id: "Nope.g/0", parent_key: "zzz", highlight: nil}
    ]

    assert {:error, msg} = Cards.prepare(index, cards)
    assert msg =~ "unknown functions: Nope.f/0, Nope.g/0"

    assert {:error, msg} =
             Cards.prepare(index, [%{key: "a", function_id: @show, parent_key: "zzz"}])

    assert msg =~ "unknown parent key: zzz"
  end

  test "a parent must come before the child that names it", %{index: index} do
    cards = [
      %{key: "child", function_id: @wrap, parent_key: "later"},
      %{key: "later", function_id: @greet}
    ]

    assert {:error, msg} = Cards.prepare(index, cards)
    assert msg =~ "unknown parent key: later"
  end

  test "highlights are checked against the function", %{index: index} do
    assert {:ok, %{"call" => "SampleApp.Greeter.greet/1"}} =
             Cards.validate_highlight(index, @show, %{call: @greet, lines: nil})

    assert {:error, msg} = Cards.validate_highlight(index, @show, %{call: @wrap, lines: nil})
    assert msg =~ "does not call"
    assert {:error, _} = Cards.validate_highlight(index, @wrap, %{call: nil, lines: [1, 2]})
    assert {:ok, nil} = Cards.validate_highlight(index, @wrap, nil)
  end

  test "an empty highlight marks nothing", %{index: index} do
    assert {:ok, nil} = Cards.validate_highlight(index, @wrap, %{})
    assert {:ok, nil} = Cards.validate_highlight(index, @wrap, %{call: nil, lines: nil})
  end

  test "a highlight names a call or a range, not both", %{index: index} do
    assert {:error, msg} = Cards.validate_highlight(index, @greet, %{call: @wrap, lines: [6, 7]})
    assert msg =~ "either"
  end

  test "a line range must read low to high and stay inside the function", %{index: index} do
    assert {:ok, %{"lines" => [6, 11]}} =
             Cards.validate_highlight(index, @greet, %{lines: [6, 11]})

    assert {:error, _} = Cards.validate_highlight(index, @greet, %{lines: [11, 6]})
    assert {:error, _} = Cards.validate_highlight(index, @greet, %{lines: [6, 12]})
    assert {:error, msg} = Cards.validate_highlight(index, @greet, %{lines: [6]})
    assert msg =~ "two line numbers"
  end

  test "a highlight on an unknown function is named", %{index: index} do
    assert {:error, msg} = Cards.validate_highlight(index, "Nope.f/0", %{lines: [1, 2]})
    assert msg =~ "unknown function: Nope.f/0"
  end
end
