defmodule Grasp.Index.EntryPoints do
  @moduledoc """
  Finds the places a project's code starts executing: routes, workers, LiveView and OTP
  callbacks, plugs.

  Runs inside the target's Mix session after compilation, so compiled modules can be
  introspected. Routers are found by their exported `__routes__/0` (`use Phoenix.Router`
  declares no behaviour); everything else by its `@behaviour` attributes, which separate a
  LiveView from a LiveComponent where their injected `__live__/0` does not.

  Which callbacks a behaviour contributes is read from the behaviour itself
  (`behaviour_info(:callbacks)`) rather than listed here, so a callback a new version of
  LiveView or Oban adds is picked up without an edit; only the handful of callbacks that
  configure the module instead of running its work (`Plug.init/1`, `Oban.Worker.new/2`,
  `GenServer.code_change/3`, ...) are denied, since they would put a row in the sidebar
  that leads nowhere.

  A callback becomes an entry point only when the index holds a definition for it:
  `use GenServer` injects default `handle_call/3` and friends that `function_exported?/3`
  reports as present, and those are noise. A live route points at the first of `mount/3`,
  `handle_params/3` and `render/1` the index holds, since `mount/3` is optional, and falls
  back to the view's first indexed function so a route whose view writes none of the three
  still appears. A router mounted with `forward` is itself in the module list, and
  `Phoenix.Router.routes/1` reports its paths relative to the mount, so each router's
  routes carry the prefix the forwards that reach it compose. Phoenix, LiveView and Oban
  are reached through `apply/3` so this package never depends on them at compile time.
  """

  alias Grasp.Index.Join

  @type entry :: %{kind: String.t(), label: String.t(), target: String.t(), meta: map()}

  @kinds ~w(route live_route oban_worker live_view live_component genserver supervisor application plug)
  @live_route_callbacks [mount: 3, handle_params: 3, render: 1]

  # Callbacks that configure the module rather than run its work: nothing calls into the
  # project through them, so they are not places a review starts.
  @configuration_callbacks %{
    Plug => [init: 1],
    Oban.Worker => [new: 2, backoff: 1, timeout: 1],
    GenServer => [code_change: 3, format_status: 1, format_status: 2],
    Application => [config_change: 3]
  }

  # A forward can mount a router that itself forwards; each pass composes one more level.
  @max_forward_depth 8

  @doc "Entry points and per-module behaviours for `app`, keeping only targets in `indexed`."
  @spec detect(atom(), MapSet.t(String.t())) :: %{
          entry_points: [entry()],
          behaviours: %{String.t() => [String.t()]}
        }
  def detect(app, indexed) do
    case app_modules(app) do
      {:ok, modules} ->
        detect_in(modules, indexed)

      :error ->
        Mix.shell().error(
          "grasp: no application modules found for #{inspect(app)}; entry points skipped"
        )

        %{entry_points: [], behaviours: %{}}
    end
  end

  @doc """
  Whether `app`'s modules can be introspected in this VM.

  `detect/2` reports no entry points and no behaviours when they cannot be, which reads
  exactly like a project that has neither. A caller rewriting part of an index —
  `Grasp.Index.Incremental` — asks first, so it keeps what the document already holds
  instead of emptying it.
  """
  @spec available?(atom() | nil) :: boolean()
  def available?(app), do: match?({:ok, _modules}, app_modules(app))

  @doc false
  @spec live_route_target(module(), MapSet.t(String.t())) :: String.t() | nil
  def live_route_target(view, indexed) do
    chain =
      Enum.find_value(@live_route_callbacks, fn {fun, arity} ->
        id = Join.function_id(view, fun, arity)
        if MapSet.member?(indexed, id), do: id
      end)

    chain || first_indexed(view, indexed)
  end

  defp first_indexed(view, indexed) do
    module = inspect(view)

    indexed
    |> Enum.filter(&(module_of(&1) == module))
    |> Enum.sort()
    |> List.first()
  end

  defp app_modules(nil), do: :error

  defp app_modules(app) do
    Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> {:ok, modules}
      :undefined -> :error
    end
  end

  defp detect_in(modules, indexed) do
    Enum.each(modules, &Code.ensure_loaded/1)

    behaviours =
      Map.new(
        modules,
        &{inspect(&1), &1 |> behaviours_of() |> Enum.map(fn b -> inspect(b) end) |> Enum.sort()}
      )

    routers = Enum.filter(modules, &function_exported?(&1, :__routes__, 0))
    prefixes = forward_prefixes(routers)

    {skipped, routes} =
      routers
      |> Enum.flat_map(&routes(&1, indexed, Map.get(prefixes, &1, "")))
      |> Enum.split_with(&(&1 == :skipped_live))

    report_skipped(length(skipped))

    controllers = MapSet.new(routes, &module_of(&1.target))
    callbacks = Enum.flat_map(modules, &module_entries(&1, indexed, controllers))

    %{
      entry_points: Enum.sort_by(routes ++ callbacks, &{rank(&1.kind), &1.label, &1.target}),
      behaviours: behaviours
    }
  end

  defp report_skipped(0), do: :ok

  defp report_skipped(count),
    do: Mix.shell().info("grasp: #{count} live routes skipped (view has no indexed functions)")

  # A forwarded router's own routes are relative to the mount, and the forward route itself
  # (`verb == :*`) is not an entry, so the mount survives only as this prefix.
  defp forward_prefixes(routers) do
    mounts =
      for router <- routers,
          route <- router_routes(router),
          route.verb == :*,
          is_atom(route.plug),
          Code.ensure_loaded?(route.plug),
          function_exported?(route.plug, :__routes__, 0),
          into: %{},
          do: {route.plug, {router, route.path}}

    Enum.reduce_while(1..@max_forward_depth, %{}, fn _pass, prefixes ->
      composed =
        Map.new(mounts, fn {router, {parent, path}} ->
          {router, join_path(Map.get(prefixes, parent, ""), path)}
        end)

      if composed == prefixes, do: {:halt, prefixes}, else: {:cont, composed}
    end)
  end

  defp join_path("", path), do: path
  defp join_path(prefix, path), do: Path.join(prefix, path)

  defp router_routes(router) do
    if Code.ensure_loaded?(Phoenix.Router),
      do: apply(Phoenix.Router, :routes, [router]),
      else: []
  end

  defp routes(router, indexed, prefix) do
    for route <- router_routes(router),
        route.verb != :*,
        is_atom(route.plug_opts),
        entry <- List.wrap(route_entry(route, router, indexed, prefix)) do
      entry
    end
  end

  defp route_entry(
         %{
           plug: Phoenix.LiveView.Plug,
           metadata: %{phoenix_live_view: {view, _action, _opts, _session}}
         } = route,
         router,
         indexed,
         prefix
       ) do
    case live_route_target(view, indexed) do
      nil -> :skipped_live
      target -> entry("live_route", target, route, router, prefix)
    end
  end

  defp route_entry(%{plug: Phoenix.LiveView.Plug}, _router, _indexed, _prefix), do: nil

  defp route_entry(%{plug: controller, plug_opts: action} = route, router, indexed, prefix) do
    target = Join.function_id(controller, action, 2)
    if MapSet.member?(indexed, target), do: entry("route", target, route, router, prefix)
  end

  defp entry(kind, target, route, router, prefix) do
    verb = route.verb |> Atom.to_string() |> String.upcase()
    path = join_path(prefix, route.path)

    %{
      kind: kind,
      label: "#{verb} #{path}",
      target: target,
      meta:
        reject_nil(%{
          "verb" => verb,
          "path" => path,
          "router" => inspect(router),
          "helper" => route.helper
        })
    }
  end

  defp module_entries(mod, indexed, controllers) do
    bs = behaviours_of(mod)

    List.flatten([
      if(Oban.Worker in bs,
        do: entries("oban_worker", mod, Oban.Worker, indexed, oban_meta(mod)),
        else: []
      ),
      if(Phoenix.LiveView in bs,
        do: entries("live_view", mod, Phoenix.LiveView, indexed, %{}),
        else: []
      ),
      if(Phoenix.LiveComponent in bs,
        do: entries("live_component", mod, Phoenix.LiveComponent, indexed, %{}),
        else: []
      ),
      if(GenServer in bs, do: entries("genserver", mod, GenServer, indexed, %{}), else: []),
      if(Supervisor in bs, do: entries("supervisor", mod, Supervisor, indexed, %{}), else: []),
      if(Application in bs, do: entries("application", mod, Application, indexed, %{}), else: []),
      if(Plug in bs and not MapSet.member?(controllers, inspect(mod)),
        do: entries("plug", mod, Plug, indexed, %{}),
        else: []
      )
    ])
  end

  defp entries(kind, mod, behaviour, indexed, meta) do
    for {fun, arity} <- callbacks_of(behaviour),
        id = Join.function_id(mod, fun, arity),
        MapSet.member?(indexed, id) do
      %{kind: kind, label: id, target: id, meta: meta}
    end
  end

  defp callbacks_of(behaviour) do
    if Code.ensure_loaded?(behaviour) and function_exported?(behaviour, :behaviour_info, 1) do
      behaviour
      |> apply(:behaviour_info, [:callbacks])
      |> Kernel.--(Map.get(@configuration_callbacks, behaviour, []))
      |> Enum.sort()
    else
      []
    end
  end

  defp oban_meta(mod) do
    opts = if function_exported?(mod, :__opts__, 0), do: apply(mod, :__opts__, [])

    if Keyword.keyword?(opts) do
      reject_nil(%{
        "queue" => to_string(Keyword.get(opts, :queue, "default")),
        "max_attempts" => Keyword.get(opts, :max_attempts)
      })
    else
      %{}
    end
  end

  defp reject_nil(meta), do: Map.reject(meta, fn {_key, value} -> is_nil(value) end)

  defp behaviours_of(mod) do
    mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  rescue
    _ -> []
  end

  defp module_of(function_id),
    do: function_id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

  defp rank(kind), do: Enum.find_index(@kinds, &(&1 == kind))
end
