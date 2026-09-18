defmodule Grasp.Application do
  @moduledoc """
  Supervision tree of Grasp: PubSub, the index store, the review comments store, the
  session and agent registries and supervisors, the MCP server the `/mcp` route forwards
  to, and — only when standalone — the viewer's own endpoint.

  The comments store follows the index store, whose project root it derives its file from
  and whose reloads it subscribes to.

  The MCP server starts explicitly rather than following the endpoint, so it also runs
  under `mix test` and inside a host application, where Grasp serves no endpoint of its
  own. It starts before the endpoint, so `/mcp` is never routable ahead of the server that
  answers it.

  Grasp is a development dependency: everything it does — reading the project's source,
  running an agent in the working tree, writing `.grasp/` — assumes a checkout and a Mix
  project. A release has neither, so when Mix is not running the tree starts empty and
  says why.

  The endpoint belongs to the standalone viewer, `mix grasp.viewer`. A host mounts Grasp
  in its own router instead, so `config :grasp, standalone: false` — the default — leaves
  the host's endpoint the only one serving.
  """

  use Application

  require Logger

  # Highlighting loads a grammar on demand, so without this the first card of a session pays
  # for the download. Elixir is what cards are written in; the rest are what Lumis injects
  # into an Elixir document — a ~H sigil, an embedded stylesheet or script.
  @languages ["elixir", "heex", "html", "css", "javascript"]

  @impl true
  def start(_type, _args) do
    mix? = mix_running?()
    if mix?, do: Lumis.Languages.async_load(@languages)

    mix?
    |> children(standalone?())
    |> Supervisor.start_link(strategy: :one_for_one, name: Grasp.Supervisor)
  end

  @doc """
  The processes Grasp starts, given whether Mix is running and whether it serves its own
  endpoint.

  Without Mix there is nothing to review, so the list is empty and a warning says so.
  """
  @spec children(boolean(), boolean()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def children(false, _standalone?) do
    Logger.warning(
      "grasp: Mix is not running, so Grasp did not start. Use it as a dev dependency."
    )

    []
  end

  def children(true, standalone?) do
    core = [
      {Phoenix.PubSub, name: Grasp.PubSub},
      {Grasp.IndexStore, []},
      {Grasp.Comments, []},
      {Registry, keys: :unique, name: Grasp.SessionRegistry},
      {DynamicSupervisor, name: Grasp.SessionSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Grasp.AgentRegistry},
      {DynamicSupervisor, name: Grasp.AgentSupervisor, strategy: :one_for_one},
      {Grasp.MCP.Server, transport: {:streamable_http, start: true}}
    ]

    if standalone?, do: core ++ [GraspWeb.Endpoint], else: core
  end

  # The flag is read once, at start; a configuration reload that flipped it afterwards would
  # otherwise send a config change to an endpoint that was never started. What is running
  # answers that without depending on the flag holding still.
  @impl true
  def config_change(changed, _new, removed) do
    if Process.whereis(GraspWeb.Endpoint), do: GraspWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp mix_running?, do: not is_nil(Application.spec(:mix, :vsn))

  defp standalone?, do: Application.get_env(:grasp, :standalone, false)
end
