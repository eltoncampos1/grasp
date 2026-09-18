defmodule GraspWeb do
  @moduledoc """
  Entry points for the web layer: `use GraspWeb, :live_view`, `:html` or `:router`.

  There is no verified-routes entry point. Grasp is mounted at a path its own router does not
  know, so every URL it writes is built from the connection or the live session rather than
  checked against a route at compile time.
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

  defp html_helpers do
    quote do
      import Phoenix.HTML
    end
  end

  @doc false
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
