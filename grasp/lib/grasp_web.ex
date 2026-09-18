defmodule GraspWeb do
  @moduledoc """
  Entry points for the web layer: `use GraspWeb, :live_view`, `:html` or `:verified_routes`.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: GraspWeb.Endpoint,
        router: GraspWeb.Router
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      unquote(verified_routes())
    end
  end

  @doc false
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
