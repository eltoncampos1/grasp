defmodule Grasp.Application do
  @moduledoc """
  Supervision tree of the Grasp viewer: PubSub, the index store, the session registry
  and supervisor, and the endpoint.

  Later tasks add `Grasp.IndexStore` and the session supervisor; in this task only PubSub
  and the endpoint start.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Grasp.PubSub},
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
