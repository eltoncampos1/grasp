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

  # Bandit reports an IPv6 literal with its brackets; `URI.parse/1` strips them.
  @local ["127.0.0.1", "localhost", "::1", "[::1]"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    if local?(conn.host) and origin_local?(conn) do
      conn
    else
      conn |> put_resp_content_type("text/plain") |> send_resp(403, "forbidden") |> halt()
    end
  end

  defp origin_local?(%Plug.Conn{} = conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _] -> local?(URI.parse(origin).host)
    end
  end

  defp local?(host) when is_binary(host), do: String.downcase(host) in @local
  defp local?(_host), do: false
end
