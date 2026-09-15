defmodule GraspWeb.Layouts do
  @moduledoc """
  The root layout. Inlines Makeup's stylesheet so token colours ship without a build step;
  everything else comes from the esbuild bundle.
  """

  use GraspWeb, :html

  @makeup_css Makeup.stylesheet(:monokai_style, "hl")

  embed_templates "layouts/*"

  @doc "Makeup's token stylesheet, scoped under `.hl`."
  @spec makeup_css() :: String.t()
  def makeup_css, do: @makeup_css
end
