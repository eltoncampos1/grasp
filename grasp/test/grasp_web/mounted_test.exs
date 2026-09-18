defmodule GraspWeb.MountedTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GraspWeb.Assets

  @endpoint GraspWeb.MountedEndpoint

  setup do
    start_supervised!(GraspWeb.MountedEndpoint)
    {:ok, conn: build_conn()}
  end

  test "the page loads its assets from under the prefix, on the host's socket", %{conn: conn} do
    html = conn |> get("/tools/grasp") |> html_response(200)

    assert html =~ ~s|src="/tools/grasp/assets/grasp.js?vsn=#{Assets.hash("grasp.js")}"|
    assert html =~ ~s|href="/tools/grasp/assets/grasp.css?vsn=#{Assets.hash("grasp.css")}"|
    assert html =~ ~s|phx-socket="/socket/live"|
  end

  test "the assets answer under the prefix", %{conn: conn} do
    conn = get(conn, "/tools/grasp/assets/grasp.js")

    assert String.starts_with?(response(conn, 200), "var Phoenix =")
  end

  test "session links are built under the prefix", %{conn: conn} do
    name = "m-#{System.unique_integer([:positive])}"
    :ok = Grasp.Session.ensure(name)

    {:ok, view, _html} = live(conn, "/tools/grasp")
    view |> element("#session-menu") |> render_click()

    assert has_element?(view, ~s(#session-list a[href="/tools/grasp/s/#{name}"]), name)
    assert has_element?(view, ~s(#session-list a[href="/tools/grasp"]), "default")
  end

  test "a named session answers under the prefix", %{conn: conn} do
    name = "m-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, "/tools/grasp/s/#{name}")

    assert has_element?(view, "#session-menu", name)
  end

  test "the agent is pointed at the MCP endpoint under the prefix", %{conn: conn} do
    name = "m-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/tools/grasp/s/#{name}")

    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()

    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "http://app.localhost:4042/tools/grasp/mcp"
  end
end
