defmodule GraspWeb.Assets do
  @moduledoc """
  Serves the two files the review page loads, both embedded in this module at compile time.

  Grasp's own bundle carries only its hooks and stylesheet. The Phoenix, `phoenix_html` and
  LiveView JavaScript in front of it is read from those applications' `priv/static`, so the
  client is always the one the host's LiveView speaks to rather than whichever version Grasp
  was built against. `@external_resource` on each file makes a change to any of them
  recompile this module, so the dev server picks up a rebuilt bundle without a restart.

  Both files answer under a `vsn` query parameter holding their content hash. A request that
  names the current hash can never be answered by a stale file, so it is cached forever; one
  that does not is revalidated every load.
  """

  @behaviour Plug

  import Plug.Conn

  vendor_paths =
    for app <- [:phoenix, :phoenix_html, :phoenix_live_view] do
      path = Application.app_dir(app, ["priv", "static", "#{app}.js"])
      Module.put_attribute(__MODULE__, :external_resource, path)
      path
    end

  js_path = Path.expand("../../../priv/static/assets/grasp.js", __DIR__)
  css_path = Path.expand("../../../priv/static/assets/grasp.css", __DIR__)

  @external_resource js_path
  @external_resource css_path

  # A concatenated file inherits the last `sourceMappingURL` it contains, which would point
  # the browser at a map describing only part of it.
  @js Enum.map_join(vendor_paths ++ [js_path], "\n", fn path ->
        path |> File.read!() |> String.replace("//# sourceMappingURL=", "// ")
      end)

  @css File.read!(css_path)

  @hashes %{
    "grasp.js" => Base.encode16(:crypto.hash(:md5, @js), case: :lower),
    "grasp.css" => Base.encode16(:crypto.hash(:md5, @css), case: :lower)
  }

  @doc "The content hash of `asset`, the `vsn` its URL carries."
  @spec hash(String.t()) :: String.t()
  def hash(asset) when is_map_key(@hashes, asset), do: Map.fetch!(@hashes, asset)

  @impl true
  def init(action), do: action

  @impl true
  def call(%Plug.Conn{} = conn, _action) do
    case fetch_query_params(conn) do
      %Plug.Conn{path_params: %{"asset" => "grasp.js"}} = conn ->
        serve(conn, "grasp.js", @js, "application/javascript")

      %Plug.Conn{path_params: %{"asset" => "grasp.css"}} = conn ->
        serve(conn, "grasp.css", @css, "text/css")

      %Plug.Conn{} = conn ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found") |> halt()
    end
  end

  # `Plug.CSRFProtection` refuses to return JavaScript to a non-XHR GET, which is exactly how
  # a script tag asks for it; the exemption says this file is Grasp's own, not the host's.
  defp serve(%Plug.Conn{} = conn, asset, contents, content_type) do
    conn
    |> put_private(:plug_skip_csrf_protection, true)
    |> put_resp_content_type(content_type)
    |> put_resp_header("cache-control", cache_control(conn, asset))
    |> send_resp(200, contents)
    |> halt()
  end

  defp cache_control(%Plug.Conn{query_params: %{"vsn" => vsn}}, asset) when is_binary(vsn) do
    if vsn == hash(asset),
      do: "public, max-age=31536000, immutable",
      else: "no-cache"
  end

  defp cache_control(%Plug.Conn{}, _asset), do: "no-cache"
end
