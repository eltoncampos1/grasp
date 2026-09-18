defmodule GraspWeb.Layouts do
  @moduledoc """
  The root layout. Inlines the Lumis theme stylesheet so token colours ship without a build
  step; everything else comes from `GraspWeb.Assets`.

  Every URL the layout writes is built from the connection rather than from a literal,
  because Grasp is mounted at a path the host chooses: the assets sit under that prefix and
  the live socket belongs to the host's endpoint, not to Grasp. `Grasp.Router.__path__/2`
  puts both under the endpoint's own script name, so a layout URL and a link the LiveView
  writes agree about where the application starts.
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
    prefix = Grasp.Router.__path__(conn, conn.private.grasp_path)

    "#{prefix}/assets/#{asset}?vsn=#{GraspWeb.Assets.hash(asset)}"
  end

  @doc """
  The path of the host endpoint's LiveView socket, as the browser must address it.
  """
  @spec live_socket_path(Plug.Conn.t()) :: String.t()
  def live_socket_path(%Plug.Conn{} = conn),
    do: Grasp.Router.__path__(conn, conn.private.live_socket_path)
end
