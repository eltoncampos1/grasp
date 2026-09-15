defmodule Grasp.Application do
  @moduledoc """
  Supervision tree of the Grasp viewer: PubSub, the index store, the session registry
  and supervisor, and the endpoint.

  The session registry and supervisor arrive in Task 3; for now PubSub, the index store
  and the endpoint start.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Grasp.PubSub},
      {Grasp.IndexStore, []},
      GraspWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Grasp.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GraspWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
