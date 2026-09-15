defmodule GraspWeb.Sidebar do
  @moduledoc """
  The sidebar's navigation: the project's entry points grouped by kind, with the module
  list as the last group.

  A review starts at the edge of the system — a request, a job, a mounted view — not at an
  alphabetical list of modules, so the groups are ordered from the outside in and only the
  routes open by default. A kind with nothing in it is not rendered at all, which is what
  makes the same sidebar readable in a library (no routes, no jobs) and in a web app.

  Callback entries name the function they are, so repeating the module on every row would
  bury the part that differs in a sidebar too narrow to hold it; each group therefore
  prints a module heading once and lists its callbacks under it by name and arity alone,
  with the full id on the row's `title`. Routes carry their own label and stay flat.
  """

  use GraspWeb, :html

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

  attr :index, Index, required: true
  attr :expanded, MapSet, required: true
  attr :expanded_module, :string, default: nil

  def entry_groups(assigns) do
    assigns =
      assign(assigns, groups: groups(assigns.index), modules: Index.modules(assigns.index))

    ~H"""
    <nav id="entries" class="entries">
      <section :for={group <- @groups} class="group" data-kind={group.kind}>
        <.group_title
          kind={group.kind}
          title={group.title}
          count={group.count}
          body_id={"group-#{group.kind}"}
          open?={open?(@expanded, group.kind)}
        />
        <div :if={open?(@expanded, group.kind)} id={"group-#{group.kind}"} class="group__body">
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
          body_id="modules"
          open?={open?(@expanded, "modules")}
        />
        <div :if={open?(@expanded, "modules")} id="modules" class="group__body">
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
        </div>
      </section>
    </nav>
    """
  end

  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :body_id, :string, required: true
  attr :open?, :boolean, required: true

  defp group_title(assigns) do
    ~H"""
    <button
      class="group__title"
      phx-click="toggle_group"
      phx-value-group={@kind}
      data-open={to_string(@open?)}
      aria-expanded={to_string(@open?)}
      aria-controls={@body_id}
    >
      {@title}<span class="group__count">{@count}</span>
    </button>
    """
  end

  defp open?(expanded, kind), do: MapSet.member?(expanded, kind)

  # Routes are listed as they come (the index already orders them by kind, label and
  # target); everything else is a callback, so it is bucketed under its module.
  defp groups(%Index{} = index) do
    by_kind = Enum.group_by(Index.entry_points(index), & &1["kind"])

    for {kind, title, kinds} <- @groups,
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

  defp by_module("routes", entries), do: [{nil, entries}]

  defp by_module(_kind, entries) do
    entries
    |> Enum.group_by(&module_of(&1["target"]))
    |> Enum.sort_by(fn {module, _entries} -> module end)
  end

  # A row under a module heading has already been told its module, and the id is too long
  # for the sidebar's width; the name and arity are what the reader is scanning for, and
  # the id stays on the row as its title.
  defp row_label(nil, entry), do: entry["label"]

  defp row_label(module, entry) do
    case entry["label"] do
      <<^module::binary, ".", rest::binary>> -> rest
      label -> label
    end
  end

  defp row_title(nil, entry), do: entry["meta"]["router"]
  defp row_title(_module, entry), do: entry["target"]

  defp module_of(target) when is_binary(target) do
    case Regex.run(@function_id, target) do
      [_match, module] -> module
      nil -> nil
    end
  end

  defp module_of(_target), do: nil
end
