defmodule Grasp.Application do
  @moduledoc """
  Supervision tree of the Grasp viewer: PubSub, the index store, the session registry
  and supervisor, and the endpoint.
  """

  use Application

  # Highlighting loads a grammar on demand, so without this the first card of a session pays
  # for the download. Elixir is what cards are written in; the rest are what Lumis injects
  # into an Elixir document — a ~H sigil, an embedded stylesheet or script.
  @languages ["elixir", "heex", "html", "css", "javascript"]

  @impl true
  def start(_type, _args) do
    Lumis.Languages.async_load(@languages)

    children = [
      {Phoenix.PubSub, name: Grasp.PubSub},
      {Grasp.IndexStore, []},
      {Registry, keys: :unique, name: Grasp.SessionRegistry},
      {DynamicSupervisor, name: Grasp.SessionSupervisor, strategy: :one_for_one},
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
