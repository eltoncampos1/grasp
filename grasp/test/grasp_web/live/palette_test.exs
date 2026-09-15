defmodule GraspWeb.PaletteTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Session

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "typing searches the index and ranks results", %{view: view} do
    view |> form("#palette-form", %{q: "greet"}) |> render_change()

    assert has_element?(
             view,
             "#palette-results li[data-id='SampleApp.Greeter.greet/2'] button",
             "SampleApp.Greeter.greet/2"
           )

    assert has_element?(view, "#palette-results li[data-id='SampleApp.Greeter.greet_all/1']")
    refute has_element?(view, "#palette-results li[data-id='SampleApp.Formatter.wrap/1']")
    assert has_element?(view, "#palette-results li:first-child[aria-selected='true']")
  end

  test "an empty query shows no results", %{view: view} do
    view |> form("#palette-form", %{q: "  "}) |> render_change()
    refute has_element?(view, "#palette-results li")
  end

  test "palette_open opens a root and closes the dialog", %{view: view} do
    render_hook(view, "palette_open", %{"id" => "SampleApp.Formatter.wrap/1", "child" => false})

    assert has_element?(
             view,
             "#card-1[data-function-id='SampleApp.Formatter.wrap/1'][data-depth='0']"
           )

    assert_push_event(view, "palette:close", %{})
  end

  test "palette_open with child: true opens under the focused card", %{view: view, name: name} do
    Session.open_root(name, "SampleApp.Greeter.greet/2")
    render_hook(view, "palette_open", %{"id" => "SampleApp.Formatter.wrap/1", "child" => true})

    assert has_element?(
             view,
             "#card-1-children #card-2[data-function-id='SampleApp.Formatter.wrap/1']"
           )
  end

  test "palette_open with child: true and no focus opens a root", %{view: view} do
    render_hook(view, "palette_open", %{"id" => "SampleApp.Formatter.wrap/1", "child" => true})
    assert has_element?(view, "#card-1[data-depth='0']")
  end
end
