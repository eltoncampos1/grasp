defmodule GraspWeb.Layouts do
  @moduledoc """
  The root layout. Inlines the Lumis theme stylesheet so token colours ship without a build
  step; everything else comes from `GraspWeb.Assets`.

  Every URL the layout writes is built from the connection rather than from a literal,
  because Grasp is mounted at a path the host chooses: the assets sit under that prefix and
  the live socket belongs to the host's endpoint, not to Grasp.
  """

  use GraspWeb, :html

  @theme_css Lumis.Theme.build_css!(Lumis.Theme.get("github_light"))

  embed_templates "layouts/*"

  @doc "The Lumis github_light stylesheet, scoped under `.lumis` / `.l-*`."
  @spec theme_css() :: String.t()
  def theme_css, do: @theme_css

  @doc """
  The URL of `asset` under the mount prefix, carrying the file's content hash as `vsn`.
  """
  @spec asset_path(Plug.Conn.t(), String.t()) :: String.t()
  def asset_path(%Plug.Conn{} = conn, asset) do
    "#{mount_prefix(conn)}/assets/#{asset}?vsn=#{GraspWeb.Assets.hash(asset)}"
  end

  @doc """
  The path of the host endpoint's LiveView socket, as the browser must address it.
  """
  @spec live_socket_path(Plug.Conn.t()) :: String.t()
  def live_socket_path(%Plug.Conn{} = conn) do
    script_prefix(conn) <> conn.private.live_socket_path
  end

  defp mount_prefix(%Plug.Conn{} = conn), do: script_prefix(conn) <> conn.private.grasp_path

  # An endpoint may itself be forwarded to from another; `script_name` is the part of the
  # path that was consumed before the router saw the request.
  defp script_prefix(%Plug.Conn{script_name: script_name}),
    do: Enum.map_join(script_name, &("/" <> &1))
end
