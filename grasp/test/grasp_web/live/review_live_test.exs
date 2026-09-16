defmodule GraspWeb.ReviewLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @shout "SampleApp.Formatter.shout/1"
  @greet_all "SampleApp.Greeter.greet_all/1"
  @show "SampleAppWeb.GreetController.show/2"
  @mount "SampleAppWeb.HelloLive.mount/3"
  @perform "SampleApp.Workers.Mailer.perform/1"
  @create "SampleAppWeb.GreetController.create/2"
  @greet_alias "SampleApp.Greeter.greet/1"
  @nested "SampleApp.Greeter.Nested.hello/0"
  @whisper "SampleApp.Formatter.whisper/1"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "the sidebar lists entry points by kind and opens their target", %{view: view} do
    assert has_element?(view, "#entries .group[data-kind='routes'] .group__title", "Routes")

    assert has_element?(
             view,
             "#entries .group[data-kind='routes'] .group__heading",
             "SampleAppWeb.Router"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='routes'] button.entry[phx-value-id='#{@show}']",
             "GET /greet/:name"
           )

    assert has_element?(view, "#group-oban[hidden]")

    view |> element("#entries .group[data-kind='oban'] .group__title") |> render_click()

    refute has_element?(view, "#group-oban[hidden]")

    assert has_element?(
             view,
             "#entries .group[data-kind='oban'] button.entry[phx-value-id='#{@perform}']",
             "perform/1"
           )

    view |> element("#entries button.entry[phx-value-id='#{@show}']") |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@show}']")
    assert has_element?(view, "#card-1 .badge", "GET /greet/:name")
  end

  test "every group but the routes starts collapsed, and callbacks sit under their module", %{
    view: view
  } do
    assert has_element?(view, "#group-genservers[hidden] button.entry")
    view |> element("#entries .group[data-kind='live'] .group__title") |> render_click()
    refute has_element?(view, "#group-live[hidden]")

    assert has_element?(
             view,
             "#entries .group[data-kind='live'] .group__heading",
             "SampleAppWeb.HelloLive"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='live'] .group__heading",
             "SampleAppWeb.GreetingComponent"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='live'] button.entry[phx-value-id='#{@mount}'][title='#{@mount}']",
             "mount/3"
           )
  end

  test "a card badges every entry point that reaches it", %{view: view, name: name} do
    Session.open_root(name, @mount)

    assert has_element?(view, "#card-1 .badge.badge--live_route", "live route")
    assert has_element?(view, "#card-1 .badge.badge--live_view", "live view")

    Session.open_root(name, @greet)
    refute has_element?(view, "#card-2 .badge")
  end

  test "renders the module list and expands a module into its functions", %{view: view} do
    assert has_element?(view, "#group-modules[hidden] #modules button.module")

    view |> element("#entries .group[data-kind='modules'] .group__title") |> render_click()

    refute has_element?(view, "#group-modules[hidden]")

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
    view |> element("#entries .group[data-kind='modules'] .group__title") |> render_click()

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

  test "a highlighted card renders the ring and the tinted lines", %{view: view, name: name} do
    Session.open_root(name, @greet)
    id = 1
    Session.set_highlight(name, id, %{"call" => @wrap})

    assert has_element?(
             view,
             ~s(#card-#{id} .call[data-highlight="true"][data-target="#{@wrap}"])
           )

    assert has_element?(view, ~s(#card-#{id}[data-highlight-key="call:#{@wrap}"]))

    Session.set_highlight(name, id, %{"lines" => [9, 10]})
    assert has_element?(view, ~s(#card-#{id} .line[data-highlight="true"][data-line="9"]))
    assert has_element?(view, ~s(#card-#{id}[data-highlight-key="lines:9-10"]))
    refute has_element?(view, ~s(#card-#{id} .call[data-highlight="true"]))
  end

  test "clicking a call opens the callee one column right and colours the call site", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()

    assert has_element?(view, ".columns .column:first-child #card-1[data-depth='0']")

    assert has_element?(
             view,
             ".columns .column:nth-child(2) #card-2[data-function-id='#{@wrap}'][data-depth='1'][data-focused='true']"
           )

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@wrap}'][data-open='true'][data-color='0'][data-edge-to='2']"
           )

    view |> element("#card-1 span.call[data-target='#{@shout}']") |> render_click()

    assert has_element?(
             view,
             ".columns .column:nth-child(2) #card-3[data-function-id='#{@shout}']"
           )

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@shout}'][data-open='true'][data-color='1'][data-edge-to='3']"
           )

    assert has_element?(view, "#card-2[data-focused='false']")

    view |> element("#card-1 span.call[data-target='#{@wrap}']") |> render_click()
    assert has_element?(view, "#card-2[data-focused='true']")
    refute has_element?(view, "#card-4")
  end

  test "a call the graph has not opened carries neither a colour nor a destination", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    assert has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-open='false']")
    refute has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-color]")
    refute has_element?(view, "#card-1 span.call[data-target='#{@wrap}'][data-edge-to]")
  end

  test "a function two cards call renders once, with a differently coloured call site in each",
       %{view: view, name: name} do
    Session.open_root(name, @create)
    Session.open_root(name, @perform)

    view |> element("#card-1 span.call[data-target='#{@greet}']") |> render_click()
    view |> element("#card-2 span.call[data-target='#{@greet_alias}']") |> render_click()

    assert count(view, ".card[data-function-id='#{@greet}']") == 1
    assert has_element?(view, ".columns .column:nth-child(2) #card-3[data-depth='1']")

    assert has_element?(
             view,
             "#card-1 span.call[data-target='#{@greet}'][data-open='true'][data-color='0'][data-edge-to='3']"
           )

    assert has_element?(
             view,
             "#card-2 span.call[data-target='#{@greet_alias}'][data-open='true'][data-color='1'][data-edge-to='3']"
           )
  end

  test "closing the middle card of a chain leaves the other two, the last one a source", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet_all)
    Session.open_child(name, 1, @greet, @greet_alias)
    Session.open_child(name, 2, @wrap)

    view |> element("#card-2 .card__close") |> render_click()

    refute has_element?(view, "#card-2")
    assert has_element?(view, ".columns .column:first-child #card-1[data-depth='0']")
    assert has_element?(view, ".columns .column:first-child #card-3[data-depth='0']")
    refute has_element?(view, ".columns .column:nth-child(2)")
  end

  test "close_chain takes the cards that had no other way to be reached", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.open_child(name, 1, @shout)
    assert has_element?(view, "#card-3")

    render_click(view, "close_chain", %{"card" => "1"})

    refute has_element?(view, "#card-1")
    refute has_element?(view, "#card-2")
    refute has_element?(view, "#card-3")
  end

  test "close_focused_chain with nothing focused leaves the canvas as it was", %{view: view} do
    render_hook(view, "close_focused_chain", %{})

    assert has_element?(view, "#stage")
    refute has_element?(view, ".card")
  end

  test "Shift+x closes the focused card's chain", %{view: view, name: name} do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)
    Session.focus(name, 1)

    render_hook(view, "close_focused_chain", %{})

    refute has_element?(view, ".card")
  end

  test "collapsing hides the callee behind a count and says so on the button", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    Session.open_child(name, 1, @wrap)

    view |> element("#card-1 .card__collapse") |> render_click()

    refute has_element?(view, "#card-2")
    assert has_element?(view, "#card-1 .card__collapse", "▸ 1")

    view |> element("#card-1 .card__collapse") |> render_click()

    assert has_element?(view, "#card-2")
    assert has_element?(view, "#card-1 .card__collapse", "▾")
    refute has_element?(view, "#card-2 .card__collapse")
  end

  test "the close button advertises the chain close", %{view: view, name: name} do
    Session.open_root(name, @greet)

    assert has_element?(
             view,
             "#card-1 .card__close[title='Close (x) · Shift+x closes the chain']"
           )
  end

  test "opening a caller puts it left of the card, which keeps its only copy", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    open_caller(view, 1, @greet_all)

    assert has_element?(
             view,
             ".columns .column:first-child #card-2[data-function-id='#{@greet_all}'][data-depth='0'][data-focused='true']"
           )

    assert has_element?(view, ".columns .column:nth-child(2) #card-1[data-depth='1']")
    assert count(view, "#card-1") == 1
    assert count(view, ".card[data-function-id='#{@greet}']") == 1

    open_caller(view, 1, @perform)

    assert count(view, ".columns .column:first-child .card") == 2

    assert has_element?(
             view,
             ".columns .column:first-child #card-3[data-function-id='#{@perform}']"
           )

    assert count(view, "#card-1") == 1
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
    open_caller(view, 1, @greet_all)

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
    open_caller(view, 1, @greet_all)

    assert has_element?(
             view,
             "#card-2 span.call[data-target='#{@greet_alias}'][data-open='true'][data-edge-to='1']"
           )

    view
    |> element("#card-2 span.call[data-target='#{@greet_alias}']")
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

  test "a hidden call opens a card one column right and marks its footer button", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet_all)

    refute has_element?(view, "#card-1 .card__also button.also[data-open='true']")

    view |> element("#card-1 .card__also button.also", @shout) |> render_click()

    assert has_element?(
             view,
             ".columns .column:nth-child(2) #card-2[data-function-id='#{@shout}']"
           )

    assert has_element?(
             view,
             "#card-1 .card__also button.also[data-open='true'][data-color='0'][data-edge-to='2']",
             @shout
           )
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

  test "a call made inside a template is listed under the view's card", %{view: view, name: name} do
    Session.open_root(name, "SampleAppWeb.HelloLive.render/1")

    assert has_element?(view, "#card-1 .card__also button.also", "SampleApp.Greeter.greet/1")
  end

  test "changes made through the session API render live", %{view: view, name: name} do
    Session.open_root(name, @greet)
    assert has_element?(view, "#card-1")
    Session.close(name, 1)
    refute has_element?(view, "#card-1")
  end

  test "keyboard focus moves along the edges", %{view: view, name: name} do
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

    # The hook draws the edges but cannot build the arrowhead they point at, so the marker
    # for every palette colour is server-rendered inside the ignored layer.
    assert has_element?(view, "#connectors defs marker#arrow-0 path[data-color='0']")
    assert has_element?(view, "#connectors defs marker#arrow-7 path[data-color='7']")
    assert has_element?(view, "#connectors g#edges")

    assert has_element?(view, "#canvas .toolbar #reset-layout[phx-click='reset_layout']")
    assert has_element?(view, "#canvas .toolbar #zoom-in")
    assert has_element?(view, "#canvas .toolbar #zoom-out")
    assert has_element?(view, "#canvas .toolbar #zoom-fit")
    assert has_element?(view, "#canvas .toolbar #zoom-level[phx-update='ignore']", "100%")
    refute has_element?(view, "#canvas .toolbar #zoom-in[phx-click]")
  end

  test "the sidebar can be hidden and shown", %{view: view} do
    assert has_element?(view, "main.app[data-sidebar='true'] aside.sidebar")

    render_hook(view, "toggle_sidebar", %{})
    refute has_element?(view, "aside.sidebar")
    assert has_element?(view, "main.app.app--no-sidebar[data-sidebar='false']")

    view |> element("#canvas .toolbar #toggle-sidebar") |> render_click()
    assert has_element?(view, "aside.sidebar")
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

  test "a modified card says so, counts its lines and offers the diff", %{view: view, name: name} do
    Session.open_root(name, @shout)

    assert has_element?(view, "#card-1 .badge--change[data-change='modified']", "modified")
    assert has_element?(view, "#card-1 .card__stats", "+1 \u22121")
    # A changed function opens on what changed.
    assert has_element?(view, "#card-1[data-view='diff']")
    assert has_element?(view, "#view-1[phx-click='toggle_view'][phx-value-card='1']", "source")
    assert has_element?(view, "#card-1 .card__body .line[data-op='del']", "text")
    assert has_element?(view, "#card-1 .card__body .line[data-op='ins'][data-line='10']")

    view |> element("#view-1") |> render_click()

    assert has_element?(view, "#card-1[data-view='source']")
    assert has_element?(view, "#view-1", "diff")
    refute has_element?(view, "#card-1 .line[data-op]")

    view |> element("#view-1") |> render_click()

    assert has_element?(view, "#card-1[data-view='diff']")
    assert has_element?(view, "#card-1 .line[data-op='del']")
  end

  test "an added card wears the added badge and has nothing to diff", %{view: view, name: name} do
    Session.open_root(name, @nested)

    assert has_element?(view, "#card-1 .badge--change[data-change='added']", "added")
    refute has_element?(view, "#card-1 .card__stats")
    refute has_element?(view, "#view-1")
  end

  test "an unchanged card wears no change badge", %{view: view, name: name} do
    Session.open_root(name, @greet)

    refute has_element?(view, "#card-1 .badge--change")
    refute has_element?(view, "#view-1")
  end

  test "a removed function opens as a removed card showing what the base had", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @whisper)

    assert has_element?(view, "#card-1.card--removed[data-function-id='#{@whisper}']")
    assert has_element?(view, "#card-1 .badge--change[data-change='removed']", "removed")
    assert has_element?(view, "#card-1 .card__body", "String.downcase")
    refute has_element?(view, "#view-1")
    refute has_element?(view, "#card-1 .card__also")
  end

  test "d toggles the focused card's view and passes over a card with no diff", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @shout)
    Session.open_root(name, @greet)

    render_hook(view, "toggle_view_focused", %{})
    assert has_element?(view, "#card-2[data-view='source']")

    Session.focus(name, 1)
    assert has_element?(view, "#card-1[data-view='diff']")
    render_hook(view, "toggle_view_focused", %{})
    assert has_element?(view, "#card-1[data-view='source']")

    render_hook(view, "toggle_view_focused", %{})
    assert has_element?(view, "#card-1[data-view='diff']")
  end

  test "the Changes group lists what the branch touched and opens it", %{view: view} do
    assert has_element?(view, "#entries .group[data-kind='changes'] .group__title", "Changes")

    assert has_element?(
             view,
             "#entries .group[data-kind='changes'] .group__title[data-open='true']"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='changes'] .group__heading",
             "SampleApp.Formatter"
           )

    assert has_element?(
             view,
             "#entries .group[data-kind='changes'] button.entry[phx-value-id='#{@whisper}'] .badge--change[data-change='removed']"
           )

    view
    |> element("#entries .group[data-kind='changes'] button.entry[phx-value-id='#{@shout}']")
    |> render_click()

    assert has_element?(view, "#card-1[data-function-id='#{@shout}'][data-depth='0']")
  end

  test "the Changes group collapses like any other", %{view: view} do
    view |> element("#entries .group[data-kind='changes'] .group__title") |> render_click()

    assert has_element?(view, "#group-changes[hidden]")
  end

  test "the project line names the base the review is against", %{view: view} do
    assert has_element?(view, ".sidebar__project", "sample_app")
    assert has_element?(view, ".sidebar__base", "main…feature")
  end

  defp open_caller(view, card_id, caller) do
    view |> element("#card-#{card_id} .card__callers-toggle") |> render_click()

    view
    |> element("#card-#{card_id} .card__callers button.caller[phx-value-caller='#{caller}']")
    |> render_click()
  end

  # has_element?/3 answers whether a selector matches at all; a graph keeps one card per
  # function, which is a statement about how many times it matches.
  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end
end
