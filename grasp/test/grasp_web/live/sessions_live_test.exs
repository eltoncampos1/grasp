defmodule GraspWeb.SessionsLiveTest do
  # Sessions are shared by the whole suite and this module deletes them and reads the
  # directory they are written to, which is application-wide state it replaces.
  use GraspWeb.ConnCase, async: false

  alias Grasp.Session
  alias Grasp.Session.Disk

  @moduletag :tmp_dir

  @greet "SampleApp.Greeter.greet/2"

  setup %{conn: conn, tmp_dir: tmp_dir} do
    previous = Application.get_env(:grasp, :sessions_dir)
    Application.put_env(:grasp, :sessions_dir, tmp_dir)
    on_exit(fn -> Application.put_env(:grasp, :sessions_dir, previous) end)

    unique = System.unique_integer([:positive])
    name = "menu-#{unique}"
    other = "other-#{unique}"
    # Sessions outlive the test that starts them, and `Grasp.Session.list/0` is what the menu
    # renders, so what this module starts it takes away again.
    on_exit(fn -> Enum.each([name, other], &Session.delete/1) end)

    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name, other: other}
  end

  test "the header names the session, and the menu marks it as the one being read", %{
    view: view,
    name: name
  } do
    assert has_element?(view, "#session-menu[aria-expanded='false']", name)
    refute has_element?(view, ".session__menu")

    view |> element("#session-menu") |> render_click()

    assert has_element?(view, "#session-menu[aria-expanded='true']")
    assert has_element?(view, ".session__menu .session__link[aria-current='true']", name)
    refute has_element?(view, ".session__menu button[phx-value-name='#{name}']")
  end

  test "a name typed into the field opens that canvas", %{view: view} do
    view |> element("#session-menu") |> render_click()

    assert {:error, {:live_redirect, %{to: "/s/review-1"}}} =
             view |> form(".session__new", %{name: "review-1"}) |> render_submit()
  end

  test "a name that is not a session name is refused and stays in the field", %{view: view} do
    view |> element("#session-menu") |> render_click()

    html = view |> form(".session__new", %{name: "../x"}) |> render_submit()

    assert html =~ "session names are letters, digits, - and _, up to 40 characters"
    assert has_element?(view, ".session__new input[value='../x']")
  end

  test "another session is listed, and deleting it forgets its cards and its file", %{
    view: view,
    name: name,
    other: other
  } do
    :ok = Session.ensure(other)
    Session.open_root(other, @greet)

    view |> element("#session-menu") |> render_click()

    assert has_element?(view, ".session__menu .session__link", other)

    view |> element(".session__menu button[phx-value-name='#{other}']") |> render_click()

    refute has_element?(view, ".session__menu .session__link", other)
    assert has_element?(view, ".session__menu .session__link[aria-current='true']", name)
    assert Disk.read(other, nil) == :empty
  end

  test "a tab reading a session that is deleted lands on the default canvas", %{
    view: view,
    name: name
  } do
    :ok = Session.delete(name)

    assert_redirect(view, "/")
  end
end
