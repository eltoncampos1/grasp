defmodule GraspWeb.ReviewLive do
  @moduledoc """
  The review page: a sidebar of modules and their functions, the card canvas, and the
  Cmd+K palette. State is the session's forest plus the loaded index; both arrive by
  PubSub so any change — from this browser, another tab, or an MCP client later — renders
  everywhere.
  """

  use GraspWeb, :live_view

  import GraspWeb.CardComponents
  import GraspWeb.Palette

  alias Grasp.{Index, IndexStore, Session}
  alias Grasp.Session.Forest

  @impl true
  def mount(params, _session, socket) do
    name = Map.get(params, "name", "default")
    :ok = Session.ensure(name)

    if connected?(socket) do
      :ok = Session.subscribe(name)
      :ok = IndexStore.subscribe()
    end

    {:ok,
     assign(socket,
       name: name,
       index: IndexStore.get(),
       forest: Session.get(name),
       expanded_module: nil,
       palette_open?: false,
       palette_query: "",
       palette_results: [],
       palette_selected: 0,
       editor: Application.get_env(:grasp, :editor)
     )}
  end

  @impl true
  def handle_info({:session, name, %Forest{} = forest}, %{assigns: %{name: name}} = socket) do
    {:noreply, socket |> assign(forest: forest) |> push_event("focus", %{id: forest.focus})}
  end

  def handle_info(:index_reloaded, socket),
    do: {:noreply, assign(socket, index: IndexStore.get())}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("expand_module", %{"module" => module}, socket) do
    expanded = if socket.assigns.expanded_module == module, do: nil, else: module
    {:noreply, assign(socket, expanded_module: expanded)}
  end

  def handle_event("open_root", %{"id" => id}, socket),
    do: mutate(socket, &Session.open_root(&1, id))

  def handle_event("open_call", %{"card" => card, "target" => target}, socket),
    do: mutate(socket, &Session.open_child(&1, int(card), target))

  def handle_event("open_caller", %{"card" => card, "caller" => caller}, socket),
    do: mutate(socket, &Session.open_caller(&1, int(card), caller))

  def handle_event("close_card", %{"card" => card}, socket),
    do: mutate(socket, &Session.close(&1, int(card)))

  def handle_event("focus_card", %{"card" => card}, socket),
    do: mutate(socket, &Session.focus(&1, int(card)))

  def handle_event("toggle_collapse", %{"card" => card}, socket),
    do: mutate(socket, &Session.toggle_collapse(&1, int(card)))

  def handle_event("move_focus", %{"dir" => dir}, socket) when dir in ~w(parent child next prev),
    do: mutate(socket, &Session.move_focus(&1, String.to_existing_atom(dir)))

  def handle_event("close_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.close(&1, id))
    end
  end

  def handle_event("collapse_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.toggle_collapse(&1, id))
    end
  end

  def handle_event("palette_show", _params, socket),
    do: {:noreply, assign(socket, palette_open?: true, palette_selected: 0)}

  def handle_event("palette_hide", _params, socket), do: {:noreply, reset_palette(socket)}

  def handle_event("palette_search", %{"q" => query}, socket) do
    results =
      case socket.assigns.index do
        nil -> []
        index -> Index.search(index, query, 20)
      end

    {:noreply,
     assign(socket, palette_query: query, palette_results: results, palette_selected: 0)}
  end

  def handle_event("palette_move", %{"delta" => delta}, socket) when delta in [1, -1] do
    last = length(socket.assigns.palette_results) - 1
    selected = (socket.assigns.palette_selected + delta) |> min(last) |> max(0)
    {:noreply, assign(socket, palette_selected: selected)}
  end

  def handle_event("palette_choose", params, socket) do
    case Enum.at(socket.assigns.palette_results, socket.assigns.palette_selected) do
      nil -> {:noreply, socket}
      fun -> open_from_palette(socket, fun["id"], child?(params))
    end
  end

  def handle_event("palette_open", %{"id" => id} = params, socket),
    do: open_from_palette(socket, id, child?(params))

  # Events are addressed by name and card id from the DOM, so a stale tab or a hand-made
  # message must be dropped rather than take the whole page down with it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The form submit carries the query rather than a child flag, so a missing key is a plain
  # root open; the hook sends the boolean and the result buttons the string.
  defp child?(params), do: params["child"] in [true, "true"]

  defp open_from_palette(socket, id, child?) do
    name = socket.assigns.name

    forest =
      case {child?, socket.assigns.forest.focus} do
        {true, focus} when is_integer(focus) -> Session.open_child(name, focus, id)
        _ -> Session.open_root(name, id)
      end

    {:noreply, socket |> assign(forest: forest) |> reset_palette()}
  end

  defp reset_palette(socket) do
    assign(socket,
      palette_open?: false,
      palette_query: "",
      palette_results: [],
      palette_selected: 0
    )
  end

  # The session broadcasts the new forest to every subscriber including this process, so
  # the returned forest is assigned here only to make the change visible before the
  # broadcast arrives (which matters in tests, where the view may not be connected).
  defp mutate(socket, fun) do
    {:noreply, assign(socket, forest: fun.(socket.assigns.name))}
  end

  # A card id that is not a number is nobody's card, and every session operation is a no-op
  # on an unknown id, so nil carries the garbage through to the same outcome.
  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp int(value) when is_integer(value), do: value

  @impl true
  def render(%{index: nil} = assigns) do
    ~H"""
    <main class="app app--empty">
      <h1 class="brand">Grasp</h1>
      <p class="empty">
        No index loaded. Start with <code>mix grasp.serve --index path/to/.grasp/index.json</code>.
      </p>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="app" id="app" phx-hook="Keys">
      <aside class="sidebar">
        <h1 class="brand">Grasp</h1>
        <p class="sidebar__project">{@index.project["app"]}</p>
        <nav id="modules" class="modules">
          <div :for={module <- Index.modules(@index)} class="module-group">
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
      </aside>
      <section class="canvas" id="canvas">
        <p :if={@forest.roots == []} class="empty">
          Pick a function from the sidebar or press <kbd>⌘K</kbd>.
        </p>
        <div class="roots">
          <.card_node
            :for={root <- @forest.roots}
            forest={@forest}
            index={@index}
            card_id={root}
            editor={@editor}
          />
        </div>
      </section>
      <.palette
        open?={@palette_open?}
        query={@palette_query}
        results={@palette_results}
        selected={@palette_selected}
      />
    </main>
    """
  end
end
