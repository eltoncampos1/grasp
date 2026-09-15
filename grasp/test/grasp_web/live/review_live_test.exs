defmodule GraspWeb.ReviewLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @shout "SampleApp.Formatter.shout/1"
  @greet_all "SampleApp.Greeter.greet_all/1"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "renders the module list and expands a module into its functions", %{view: view} do
    assert has_element?(view, "#modules button.module", "SampleApp.Greeter")
    refute has_element?(view, "#modules button.fn", "greet/2")

    view
    |> element("#modules button.module[phx-value-module='SampleApp.Greeter']")
    |> render_click()

    assert has_element?(view, "#modules button.fn", "greet/2")
  end

  test "opening a function from the sidebar adds a focused root card with highlighted source", %{
    view: view
  } do
    view
    |> element("#modules button.module[phx-value-module='SampleApp.Greeter']")
    |> render_click()

    view |> element("#modules button.fn[phx-value-id='#{@greet}']") |> render_click()

    assert has_element?(
             view,
             "#card-1[data-function-id='#{@greet}'][data-focused='true'][data-depth='0']"
           )

    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}']", "Formatter.wrap")
    assert has_element?(view, "#card-1 .card__file", "lib/sample_app/greeter.ex:6")
  end

  test "clicking a call opens the callee as a child; clicking again focuses it", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()

    assert has_element?(
             view,
             "#card-1-children #card-2[data-function-id='#{@wrap}'][data-depth='1'][data-focused='true']"
           )

    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-open='true']")

    view |> element("#card-1 span.call[data-target='#{@shout}']") |> render_click()
    assert has_element?(view, "#card-1-children #card-3[data-function-id='#{@shout}']")
    assert has_element?(view, "#card-2[data-focused='false']")

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    assert has_element?(view, "#card-2[data-focused='true']")
    refute has_element?(view, "#card-4")
  end

  test "closing a card removes its subtree; collapsing hides it behind a count", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.open_child(name, 1, @shout)

    view |> element("#card-1 .card__collapse") |> render_click()
    refute has_element?(view, "#card-2")
    assert has_element?(view, "#card-1 .card__collapse", "2")

    view |> element("#card-1 .card__collapse") |> render_click()
    assert has_element?(view, "#card-2")

    view |> element("#card-2 .card__close") |> render_click()
    refute has_element?(view, "#card-2")
    assert has_element?(view, "#card-3")

    view |> element("#card-1 .card__close") |> render_click()
    refute has_element?(view, "#card-1")
    refute has_element?(view, "#card-3")
  end

  test "opening a caller from a root re-parents the tree", %{view: view, name: name} do
    Session.open_root(name, @greet)

    view
    |> element("#card-1 .card__callers button.caller[phx-value-caller='#{@greet_all}']")
    |> render_click()

    assert has_element?(
             view,
             "#card-2[data-function-id='#{@greet_all}'][data-depth='0'][data-focused='true']"
           )

    assert has_element?(view, "#card-2-children #card-1[data-depth='1']")
  end

  test "an external call opens a stub card", %{view: view, name: name} do
    Session.open_root(name, @greet_all)

    view
    |> element("#card-1 span.call[data-target='Enum.map/2'][data-external='true']")
    |> render_click()

    assert has_element?(view, "#card-2.stub", "Enum.map/2")
    assert has_element?(view, "#card-2.stub a[href='https://hexdocs.pm/elixir/Enum.html#map/2']")
  end

  test "hidden calls are listed under the card", %{view: view, name: name} do
    Session.open_root(name, @greet_all)
    assert has_element?(view, "#card-1 .card__also", @shout)
  end

  test "changes made through the session API render live", %{view: view, name: name} do
    Session.open_root(name, @greet)
    assert has_element?(view, "#card-1")
    Session.close(name, 1)
    refute has_element?(view, "#card-1")
  end

  test "keyboard focus moves through the tree", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.focus(name, 2)

    render_hook(view, "move_focus", %{"dir" => "parent"})
    assert has_element?(view, "#card-1[data-focused='true']")
    render_hook(view, "move_focus", %{"dir" => "child"})
    assert has_element?(view, "#card-2[data-focused='true']")
  end
end
