defmodule Grasp.Index.EntryPoints do
  @moduledoc """
  Finds the places a project's code starts executing: routes, workers, LiveView and OTP
  callbacks, plugs.

  Runs inside the target's Mix session after compilation, so compiled modules can be
  introspected. Routers are found by their exported `__routes__/0` (`use Phoenix.Router`
  declares no behaviour); everything else by `@behaviour` attributes or `__live__/0`.
  A callback becomes an entry point only when the index holds a definition for it:
  `use GenServer` injects default `handle_call/3` and friends that `function_exported?/3`
  reports as present, and those are noise. Phoenix, LiveView and Oban are reached through
  `apply/3` so this package never depends on them at compile time.
  """

  alias Grasp.Index.Join

  @type entry :: %{kind: String.t(), label: String.t(), target: String.t(), meta: map()}

  @kinds ~w(route live_route oban_worker live_view live_component genserver supervisor application plug)
  @live_callbacks [
    mount: 3,
    handle_params: 3,
    handle_event: 3,
    handle_info: 2,
    handle_async: 3,
    render: 1
  ]
  @component_callbacks [update: 2, handle_event: 3, render: 1]
  @genserver_callbacks [
    init: 1,
    handle_call: 3,
    handle_cast: 2,
    handle_info: 2,
    handle_continue: 2,
    terminate: 2
  ]

  @doc "Entry points and per-module behaviours for `app`, keeping only targets in `indexed`."
  @spec detect(atom(), MapSet.t(String.t())) :: %{
          entry_points: [entry()],
          behaviours: %{String.t() => [String.t()]}
        }
  def detect(app, indexed) do
    Application.load(app)
    {:ok, modules} = :application.get_key(app, :modules)
    Enum.each(modules, &Code.ensure_loaded/1)

    behaviours =
      Map.new(
        modules,
        &{inspect(&1), &1 |> behaviours_of() |> Enum.map(fn b -> inspect(b) end) |> Enum.sort()}
      )

    routes =
      modules
      |> Enum.filter(&function_exported?(&1, :__routes__, 0))
      |> Enum.flat_map(&routes(&1, indexed))

    controllers = MapSet.new(routes, &module_of(&1.target))
    callbacks = Enum.flat_map(modules, &module_entries(&1, indexed, controllers))

    %{
      entry_points: Enum.sort_by(routes ++ callbacks, &{rank(&1.kind), &1.label, &1.target}),
      behaviours: behaviours
    }
  end

  defp routes(router, indexed) do
    if Code.ensure_loaded?(Phoenix.Router) do
      for route <- apply(Phoenix.Router, :routes, [router]),
          route.verb != :*,
          is_atom(route.plug_opts),
          {kind, target} <- List.wrap(route_target(route, indexed)) do
        verb = route.verb |> Atom.to_string() |> String.upcase()

        %{
          kind: kind,
          label: "#{verb} #{route.path}",
          target: target,
          meta: %{
            "verb" => verb,
            "path" => route.path,
            "router" => inspect(router),
            "helper" => route.helper
          }
        }
      end
    else
      []
    end
  end

  defp route_target(
         %{
           plug: Phoenix.LiveView.Plug,
           metadata: %{phoenix_live_view: {view, _action, _opts, _session}}
         },
         indexed
       ) do
    keep({"live_route", Join.function_id(view, :mount, 3)}, indexed)
  end

  defp route_target(%{plug: Phoenix.LiveView.Plug}, _indexed), do: nil

  defp route_target(%{plug: controller, plug_opts: action}, indexed),
    do: keep({"route", Join.function_id(controller, action, 2)}, indexed)

  defp module_entries(mod, indexed, controllers) do
    bs = behaviours_of(mod)
    live? = Phoenix.LiveView in bs or function_exported?(mod, :__live__, 0)

    List.flatten([
      if(Oban.Worker in bs,
        do: entries("oban_worker", mod, [perform: 1], indexed, oban_meta(mod)),
        else: []
      ),
      if(live?, do: entries("live_view", mod, @live_callbacks, indexed, %{}), else: []),
      if(Phoenix.LiveComponent in bs,
        do: entries("live_component", mod, @component_callbacks, indexed, %{}),
        else: []
      ),
      if(GenServer in bs,
        do: entries("genserver", mod, @genserver_callbacks, indexed, %{}),
        else: []
      ),
      if(Supervisor in bs, do: entries("supervisor", mod, [init: 1], indexed, %{}), else: []),
      if(Application in bs, do: entries("application", mod, [start: 2], indexed, %{}), else: []),
      if(Plug in bs and not MapSet.member?(controllers, inspect(mod)),
        do: entries("plug", mod, [call: 2], indexed, %{}),
        else: []
      )
    ])
  end

  defp entries(kind, mod, callbacks, indexed, meta) do
    for {fun, arity} <- callbacks,
        id = Join.function_id(mod, fun, arity),
        MapSet.member?(indexed, id) do
      %{kind: kind, label: id, target: id, meta: meta}
    end
  end

  defp keep({_kind, target} = entry, indexed),
    do: if(MapSet.member?(indexed, target), do: entry)

  defp oban_meta(mod) do
    if function_exported?(mod, :__opts__, 0) do
      opts = apply(mod, :__opts__, [])

      %{
        "queue" => to_string(Keyword.get(opts, :queue, "default")),
        "max_attempts" => Keyword.get(opts, :max_attempts)
      }
    else
      %{}
    end
  end

  defp behaviours_of(mod) do
    mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  rescue
    _ -> []
  end

  defp module_of(function_id),
    do: function_id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

  defp rank(kind), do: Enum.find_index(@kinds, &(&1 == kind))
end
