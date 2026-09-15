defmodule GraspWeb.Layouts do
  @moduledoc """
  The root layout. Inlines the Lumis theme stylesheet so token colours ship without a build
  step; everything else comes from the esbuild bundle.
  """

  use GraspWeb, :html

  @theme_css Lumis.Theme.build_css!(Lumis.Theme.get("github_light"))

  embed_templates "layouts/*"

  @doc "The Lumis github_light stylesheet, scoped under `.lumis` / `.l-*`."
  @spec theme_css() :: String.t()
  def theme_css, do: @theme_css
end
