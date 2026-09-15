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

    view |> element("#card-1 .card__callers-toggle") |> render_click()

    view
    |> element("#card-1 .card__callers button.caller[phx-value-caller='#{@greet_all}']")
    |> render_click()

    assert has_element?(
             view,
             "#card-2[data-function-id='#{@greet_all}'][data-depth='0'][data-focused='true']"
           )

    assert has_element?(view, "#card-2-children #card-1[data-depth='1']")
  end

  test "the callers menu opens on click, focuses its card and closes again", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    assert has_element?(view, "#card-1[data-focused='false']")
    refute has_element?(view, "#card-1 .card__callers ul")

    view |> element("#card-1 .card__callers-toggle") |> render_click()
    assert has_element?(view, "#card-1 .card__callers ul button.caller", @greet_all)
    assert has_element?(view, "#card-1[data-focused='true']")

    view |> element("#card-1 .card__callers-toggle") |> render_click()
    refute has_element?(view, "#card-1 .card__callers ul")
  end

  test "opening a caller closes the callers menu", %{view: view, name: name} do
    Session.open_root(name, @greet)
    view |> element("#card-1 .card__callers-toggle") |> render_click()

    view
    |> element("#card-1 .card__callers button.caller[phx-value-caller='#{@greet_all}']")
    |> render_click()

    refute has_element?(view, ".card__callers ul")
  end

  test "an arity alias resolves to the defining function", %{view: view, name: name} do
    Session.open_root(name, @greet_all)

    view
    |> element("#card-1 span.call[data-target='SampleApp.Greeter.greet/1']")
    |> render_click()

    assert has_element?(view, "#card-2[data-function-id='#{@greet}']")
    refute has_element?(view, "#card-3")
  end

  test "a call through an arity alias marks the open child and reuses it", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    view |> element("#card-1 .card__callers-toggle") |> render_click()

    view
    |> element("#card-1 .card__callers button.caller[phx-value-caller='#{@greet_all}']")
    |> render_click()

    assert has_element?(
             view,
             "#card-2 span.call[data-target='SampleApp.Greeter.greet/1'][data-open='true']"
           )

    view
    |> element("#card-2 span.call[data-target='SampleApp.Greeter.greet/1']")
    |> render_click()

    assert has_element?(view, "#card-1[data-focused='true']")
    refute has_element?(view, "#card-3")
  end

  test "a non-string id or target is ignored", %{view: view, name: name} do
    Session.open_root(name, @greet)

    render_hook(view, "palette_open", %{"id" => 123, "child" => false})
    render_click(view, "open_call", %{"card" => "1", "target" => 5})
    render_click(view, "open_root", %{"id" => %{"a" => 1}})
    render_click(view, "open_caller", %{"card" => "1", "caller" => 7})
    render_click(view, "focus_card", %{"card" => %{"a" => 1}})
    render_click(view, "toggle_callers", %{"card" => ["1"]})

    assert has_element?(view, "#card-1")
    refute has_element?(view, "#card-2")
  end

  test "a hidden call opens a child card", %{view: view, name: name} do
    Session.open_root(name, @greet_all)

    view |> element("#card-1 .card__also button.also", @shout) |> render_click()

    assert has_element?(view, "#card-1-children #card-2[data-function-id='#{@shout}']")
  end

  test "opening a call pushes a focus event for the new card", %{view: view, name: name} do
    Session.open_root(name, @greet)

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    render(view)

    assert_push_event(view, "focus", %{id: 2})
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

  test "the header focuses a card, and the card body does not", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    assert has_element?(view, "#card-2[data-focused='true']")

    view |> element("#card-1 .card__header") |> render_click()
    assert has_element?(view, "#card-1[data-focused='true']")
    refute has_element?(view, "#card-1[phx-click]")
  end

  test "the bare route serves the default session", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#app .sidebar .brand", "Grasp")
    assert has_element?(view, "#canvas")
  end

  test "the canvas wraps the cards in a pannable stage with a connector layer and a toolbar",
       %{view: view} do
    assert has_element?(
             view,
             "#canvas[phx-hook='Canvas'] #stage svg#connectors[phx-update='ignore']"
           )

    assert has_element?(view, "#canvas .toolbar #reset-layout[phx-click='reset_layout']")
    assert has_element?(view, "#canvas .toolbar #zoom-in")
    assert has_element?(view, "#canvas .toolbar #zoom-out")
    assert has_element?(view, "#canvas .toolbar #zoom-fit")
    refute has_element?(view, "#canvas .toolbar #zoom-in[phx-click]")
  end

  test "dragging a card stores its offset and reset_layout clears it", %{view: view, name: name} do
    Session.open_root(name, @greet)

    render_hook(view, "move_card", %{"card" => 1, "dx" => 40, "dy" => -12})
    assert has_element?(view, "#card-1[data-dx='40'][data-dy='-12']")
    assert has_element?(view, ".node[style*='--dx: 40px'] > #card-1")

    render_hook(view, "move_card", %{"card" => "1", "dx" => "7", "dy" => "8"})
    assert has_element?(view, "#card-1[data-dx='7'][data-dy='8']")

    render_hook(view, "move_card", %{"card" => 1, "dx" => "nope", "dy" => 0})
    assert has_element?(view, "#card-1[data-dx='7']")

    render_click(view, "reset_layout", %{})
    assert has_element?(view, "#card-1[data-dx='0'][data-dy='0']")
  end

  test "an unhandled direction or an unparsable card id leaves the view alive", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    render_hook(view, "move_focus", %{"dir" => "sideways"})
    render_click(view, "close_card", %{"card" => "abc"})
    render_click(view, "nonsense", %{})

    assert render(view) =~ "card-1"
    assert has_element?(view, "#card-1")
  end
end
