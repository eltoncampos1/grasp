defmodule GraspWeb.MountedTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn
  import Phoenix.LiveViewTest

  alias GraspWeb.Assets

  @endpoint GraspWeb.MountedEndpoint

  # The only module that names this endpoint, so it is started once for the whole of it.
  setup_all do
    start_supervised!(GraspWeb.MountedEndpoint)
    :ok
  end

  # `Grasp.Plug` guards the mount, and ConnTest's default host is not a loopback name.
  setup do
    {:ok, conn: %{build_conn() | host: "127.0.0.1"}}
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

  # The router's browser pipeline declares `plug :accepts, ["html"]`, which would refuse this
  # request: reaching the transport at all is the point of serving it from the endpoint.
  test "the MCP endpoint answers under the prefix, in front of the router", %{conn: conn} do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "mounted-test", "version" => "0"}
      }
    }

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/tools/grasp/mcp", Jason.encode!(body))

    assert response(conn, 200) =~ ~s("serverInfo")
  end

  test "the page and its assets are refused from a host that is not loopback", %{conn: conn} do
    conn = %{conn | host: "www.example.com"}

    assert conn |> get("/tools/grasp") |> response(403) == "forbidden"
    assert conn |> get("/tools/grasp/assets/grasp.js") |> response(403) == "forbidden"
    assert conn |> get("/tools/grasp/s/anything") |> response(403) == "forbidden"
  end

  # Not 403: a path the host serves itself is none of Grasp's business, whoever asks for it.
  test "a request outside the mount is left to the host", %{conn: conn} do
    assert %{conn | host: "www.example.com"} |> get("/users") |> response(404)
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
