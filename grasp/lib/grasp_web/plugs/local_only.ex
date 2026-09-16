defmodule GraspWeb.Plugs.LocalOnly do
  @moduledoc """
  Rejects a request that did not come from the loopback interface.

  Binding the viewer to `127.0.0.1` does not by itself keep a browser out: a page on an
  attacker's domain whose DNS rebinds to `127.0.0.1` becomes same-origin with the viewer,
  so the browser applies no cross-origin check and the page can read whatever the endpoint
  serves — for `/mcp`, every indexed function's source. Checking the `Host` the request was
  addressed to, and the `Origin` the browser declares when it sends one, is what the MCP
  specification asks of a local HTTP transport.
  """

  @behaviour Plug

  import Plug.Conn

  @local ["127.0.0.1", "localhost", "::1"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    if conn.host in @local and origin_local?(conn) do
      conn
    else
      conn |> send_resp(403, "forbidden") |> halt()
    end
  end

  defp origin_local?(%Plug.Conn{} = conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> URI.parse(origin).host in @local
    end
  end
end
