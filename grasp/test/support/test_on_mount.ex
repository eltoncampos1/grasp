defmodule GraspWeb.TestOnMount do
  @moduledoc """
  A no-op `on_mount` hook for the stand-in host router.

  It exists so the suite can prove two things about `Grasp.Router.grasp/2`: that `:on_mount`
  reaches the generated live session, and that a module written there as an alias resolves in
  the host router's own context rather than inside the scope the macro opens.
  """

  @doc "Continues the mount unchanged."
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket), do: {:cont, socket}
end
