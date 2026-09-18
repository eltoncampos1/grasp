defmodule Grasp.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "plug-test", "version" => "0"}
    }
  }

  defp request(path, host \\ "127.0.0.1") do
    %{build_conn(:post, path, Jason.encode!(@initialize)) | host: host}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  test "a request outside the mount passes through untouched" do
    conn = Grasp.Plug.call(request("/users"), Grasp.Plug.init([]))

    refute conn.halted
    refute conn.state == :sent
  end

  test "a request under the mount from a host that is not loopback is refused" do
    opts = Grasp.Plug.init([])

    for path <- ["/grasp", "/grasp/s/foo", "/grasp/assets/grasp.js", "/grasp/mcp"] do
      conn = Grasp.Plug.call(request(path, "evil.example"), opts)

      assert conn.halted, path
      assert response(conn, 403) == "forbidden"
    end
  end

  test "a request under the mount that is not the transport passes through to the router" do
    conn = Grasp.Plug.call(request("/grasp/s/foo"), Grasp.Plug.init([]))

    refute conn.halted
    refute conn.state == :sent
  end

  test "the mount's `mcp` serves the transport" do
    conn = Grasp.Plug.call(request("/grasp/mcp"), Grasp.Plug.init([]))

    assert conn.halted
    assert response(conn, 200) =~ ~s("serverInfo")
  end

  test "`:at` moves the guard and the transport with it" do
    opts = Grasp.Plug.init(at: "/tools/grasp")

    assert response(Grasp.Plug.call(request("/tools/grasp/mcp"), opts), 200) =~ ~s("serverInfo")

    assert response(Grasp.Plug.call(request("/tools/grasp", "evil.example"), opts), 403) ==
             "forbidden"

    assert %Plug.Conn{halted: false} = Grasp.Plug.call(request("/grasp/mcp"), opts)
  end

  test "`:mcp` moves the transport alone" do
    opts = Grasp.Plug.init(at: "/grasp", mcp: "/grasp/agent")

    assert response(Grasp.Plug.call(request("/grasp/agent"), opts), 200) =~ ~s("serverInfo")
    assert %Plug.Conn{halted: false} = Grasp.Plug.call(request("/grasp/mcp"), opts)
  end

  test "`at: \"/\"` guards everything, which is what the standalone server wants" do
    opts = Grasp.Plug.init(at: "/")

    assert response(Grasp.Plug.call(request("/users", "evil.example"), opts), 403) == "forbidden"
    assert response(Grasp.Plug.call(request("/mcp"), opts), 200) =~ ~s("serverInfo")
  end
end
