defmodule GraspWeb.Sidebar do
  @moduledoc """
  The sidebar's navigation: the project's entry points grouped by kind, with the module
  list as the last group.

  A review starts at the edge of the system — a request, a job, a mounted view — not at an
  alphabetical list of modules, so the groups are ordered from the outside in. A kind with
  nothing in it is not rendered at all, which is what makes the same sidebar readable in a
  library (no routes, no jobs) and in a web app; a kind the viewer has no group for still
  lands in "Other", so an entry the indexer learns to find is never invisible here.

  Entries name the function they are, so repeating the module on every row would bury the
  part that differs in a sidebar too narrow to hold it; each group therefore prints a
  heading once and lists what is under it by name and arity alone, with the full id on the
  row's `title`. Routes are headed by their router — a forwarded router is a section of the
  URL space, and its rows keep their `VERB /path` label, ordered by path.

  A review against a base ref leads with what the branch did: a Changes group above the
  entry points, listing every added, modified and removed function under its module with
  the badge naming which it is. It is the table of contents of a pull request, so it opens
  on arrival whenever there is one, and is absent from a review with nothing to show — no
  base ref, or a branch that changed nothing.

  Which group opens on arrival is decided by `default_expanded/1`, at mount and again
  whenever the index reloads: the changes whenever there are any, the routes when there are
  few enough to read as a list, the module list when there are no entry points at all.
  Every group's body is rendered
  either way and hidden when collapsed, so the `aria-controls` on its title always names an
  element.
  """

  use GraspWeb, :html

  import GraspWeb.CardComponents, only: [change_badge: 1]

  alias Grasp.Index

  @function_id ~r/^([A-Z][\w.]*)\.[^.\/]+\/\d+$/

  # Ordered from the outside in: what calls into the system, then what the runtime calls,
  # then the plumbing. Each entry is {data-kind, title, kinds it collects}.
  @groups [
    {"routes", "Routes", ["route", "live_route"]},
    {"oban", "Background jobs", ["oban_worker"]},
    {"live", "Live views", ["live_view", "live_component"]},
    {"genservers", "Processes", ["genserver"]},
    {"otp", "Supervision", ["supervisor", "application"]},
    {"plugs", "Plugs", ["plug"]}
  ]

  @known_kinds Enum.flat_map(@groups, fn {_kind, _title, kinds} -> kinds end)
  @group_kinds ["changes"] ++
                 Enum.map(@groups, fn {kind, _title, _kinds} -> kind end) ++ ~w(other modules)

  # Past this many routes the list is a wall rather than a table of contents, and the
  # reader is better served by the search palette.
  @routes_open_max 50

  @doc "Every group the sidebar can render, as the `data-kind` its title toggles."
  @spec group_kinds() :: [String.t()]
  def group_kinds, do: @group_kinds

  @doc """
  The groups a review of `index` opens with.

  What the branch changed is why a reviewer is here at all, so it opens whenever there is
  any. The routes are the table of contents of a web app, so they open while they still
  read as one; a project with no entry points at all is a library, where the module list is
  the only way in.
  """
  @spec default_expanded(Index.t() | nil) :: MapSet.t(String.t())
  def default_expanded(nil), do: MapSet.new()

  def default_expanded(%Index{} = index) do
    groups = groups(index)
    routes = Enum.find(groups, &(&1.kind == "routes"))

    entries =
      cond do
        routes && routes.count <= @routes_open_max -> MapSet.new(["routes"])
        groups == [] -> MapSet.new(["modules"])
        true -> MapSet.new()
      end

    case Index.changed_functions(index) do
      [] -> entries
      _changes -> MapSet.put(entries, "changes")
    end
  end

  attr :index, Index, required: true
  attr :expanded, MapSet, required: true
  attr :expanded_module, :string, default: nil

  def entry_groups(assigns) do
    changes = Index.changed_functions(assigns.index)

    assigns =
      assign(assigns,
        groups: groups(assigns.index),
        modules: Index.modules(assigns.index),
        changes: changes_by_module(changes),
        change_count: length(changes)
      )

    ~H"""
    <nav id="entries" class="entries">
      <section :if={@changes != []} class="group" data-kind="changes">
        <.group_title
          kind="changes"
          title="Changes"
          count={@change_count}
          open?={open?(@expanded, "changes")}
        />
        <div
          id="group-changes"
          class="group__body"
          hidden={not open?(@expanded, "changes")}
        >
          <div :for={{module, records} <- @changes} class="group__module">
            <h2 class="group__heading">{module}</h2>
            <button
              :for={record <- records}
              class="entry"
              phx-click="open_root"
              phx-value-id={record["id"]}
              title={record["id"]}
            >
              <.change_badge change={record["change"]} />{record["name"]}/{record["arity"]}
            </button>
          </div>
        </div>
      </section>
      <section :for={group <- @groups} class="group" data-kind={group.kind}>
        <.group_title
          kind={group.kind}
          title={group.title}
          count={group.count}
          open?={open?(@expanded, group.kind)}
        />
        <div
          id={"group-#{group.kind}"}
          class="group__body"
          hidden={not open?(@expanded, group.kind)}
        >
          <div :for={{module, entries} <- group.modules} class="group__module">
            <h2 :if={module} class="group__heading">{module}</h2>
            <button
              :for={entry <- entries}
              class="entry"
              phx-click="open_root"
              phx-value-id={entry["target"]}
              title={row_title(module, entry)}
            >
              {row_label(module, entry)}
            </button>
          </div>
        </div>
      </section>
      <section class="group" data-kind="modules">
        <.group_title
          kind="modules"
          title="Modules"
          count={length(@modules)}
          open?={open?(@expanded, "modules")}
        />
        <div id="group-modules" class="group__body" hidden={not open?(@expanded, "modules")}>
          <nav id="modules">
            <div :for={module <- @modules} class="module-group">
              <button
                class={["module", @expanded_module == module["name"] && "module--open"]}
                phx-click="expand_module"
                phx-value-module={module["name"]}
              >
                {module["name"]}
              </button>
              <ul :if={@expanded_module == module["name"]} class="fns">
                <li :for={fun <- Index.functions_in_module(@index, module["name"])}>
                  <button
                    class={["fn", "fn--#{fun["kind"]}"]}
                    phx-click="open_root"
                    phx-value-id={fun["id"]}
                  >
                    {fun["name"]}/{fun["arity"]}
                  </button>
                </li>
              </ul>
            </div>
          </nav>
        </div>
      </section>
    </nav>
    """
  end

  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :open?, :boolean, required: true

  defp group_title(assigns) do
    ~H"""
    <button
      class="group__title"
      phx-click="toggle_group"
      phx-value-group={@kind}
      data-open={to_string(@open?)}
      aria-expanded={to_string(@open?)}
      aria-controls={"group-#{@kind}"}
    >
      {@title}<span class="group__count">{@count}</span>
    </button>
    """
  end

  defp open?(expanded, kind), do: MapSet.member?(expanded, kind)

  defp groups(%Index{} = index) do
    by_kind = Enum.group_by(Index.entry_points(index), & &1["kind"])
    other = {"other", "Other", by_kind |> Map.keys() |> Kernel.--(@known_kinds) |> Enum.sort()}

    for {kind, title, kinds} <- @groups ++ [other],
        entries = Enum.flat_map(kinds, &Map.get(by_kind, &1, [])),
        entries != [] do
      %{
        kind: kind,
        title: title,
        count: length(entries),
        modules: by_module(kind, entries)
      }
    end
  end

  # Changed functions arrive sorted by id, which orders each module's rows the way the
  # module list orders them; grouping preserves that, so only the headings need sorting.
  defp changes_by_module(records) do
    records |> Enum.group_by(& &1["module"]) |> Enum.sort_by(fn {module, _records} -> module end)
  end

  # A route is not a callback on a module: what it belongs to is the router that declared
  # it, and a path reads as a list only in path order.
  defp by_module("routes", entries) do
    entries
    |> Enum.group_by(&meta(&1, "router"))
    |> Enum.sort_by(fn {router, _entries} -> router end)
    |> Enum.map(fn {router, routes} ->
      {router, Enum.sort_by(routes, &{meta(&1, "path"), meta(&1, "verb")})}
    end)
  end

  defp by_module(_kind, entries) do
    entries
    |> Enum.group_by(&module_of(&1["target"]))
    |> Enum.sort_by(fn {module, _entries} -> module end)
  end

  defp meta(entry, key), do: Map.get(entry["meta"] || %{}, key)

  # A row under a heading has already been told its module, and the id is too long for the
  # sidebar's width; the name and arity are what the reader is scanning for, and the id
  # stays on the row as its title.
  defp row_label(nil, entry), do: entry["label"]

  defp row_label(module, entry) do
    case entry["label"] do
      <<^module::binary, ".", rest::binary>> -> rest
      label -> label
    end
  end

  defp row_title(_module, entry), do: entry["target"]

  defp module_of(target) when is_binary(target) do
    case Regex.run(@function_id, target) do
      [_match, module] -> module
      nil -> nil
    end
  end

  defp module_of(_target), do: nil
end
