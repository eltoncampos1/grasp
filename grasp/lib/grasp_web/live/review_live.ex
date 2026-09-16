defmodule GraspWeb.ReviewLive do
  @moduledoc """
  The review page: a sidebar that starts from the project's entry points — routes, jobs,
  live views, processes — with the module list as its last group, the card canvas, and the
  Cmd+K palette. Which sidebar groups arrive open is the sidebar's decision, taken once
  from the index at mount and then owned by whoever clicks. State is the session's forest plus the loaded index; both arrive by
  PubSub so any change — from this browser, another tab, or an MCP client later — renders
  everywhere.
  """

  use GraspWeb, :live_view

  import GraspWeb.CardComponents
  import GraspWeb.ChatPanel
  import GraspWeb.Palette
  import GraspWeb.Sidebar

  alias Grasp.{Index, IndexStore, Links, Session}
  alias Grasp.Session.Forest

  @groups GraspWeb.Sidebar.group_kinds()
  @no_command "claude command not found; set GRASP_AGENT_COMMAND"

  @impl true
  def mount(params, _session, socket) do
    name = Map.get(params, "name", "default")
    :ok = Session.ensure(name)
    :ok = Grasp.Agent.ensure(name)

    if connected?(socket) do
      :ok = Session.subscribe(name)
      :ok = Grasp.Agent.subscribe(name)
      :ok = IndexStore.subscribe()
    end

    index = IndexStore.get()

    {:ok,
     assign(socket,
       name: name,
       index: index,
       index_error: IndexStore.last_error(),
       index_path: IndexStore.path(),
       forest: Session.get(name),
       expanded_module: nil,
       expanded_groups: default_expanded(index),
       callers_open: nil,
       palette_open?: false,
       palette_query: "",
       palette_results: [],
       palette_selected: 0,
       sidebar_open?: true,
       chat_open?: false,
       chat_error: nil,
       agent: Grasp.Agent.get(name),
       editor: Application.get_env(:grasp, :editor)
     )}
  end

  @impl true
  def handle_info({:session, name, %Forest{} = forest}, %{assigns: %{name: name}} = socket) do
    {:noreply, socket |> assign(forest: forest) |> push_event("focus", %{id: forest.focus})}
  end

  def handle_info({:agent, name, view}, %{assigns: %{name: name}} = socket),
    do: {:noreply, assign(socket, agent: view)}

  def handle_info(:index_reloaded, socket),
    do:
      {:noreply,
       assign(socket,
         index: IndexStore.get(),
         index_error: IndexStore.last_error(),
         index_path: IndexStore.path()
       )}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_group", %{"group" => group}, socket) when group in @groups do
    groups = socket.assigns.expanded_groups

    toggled =
      if MapSet.member?(groups, group),
        do: MapSet.delete(groups, group),
        else: MapSet.put(groups, group)

    {:noreply, assign(socket, expanded_groups: toggled)}
  end

  def handle_event("expand_module", %{"module" => module}, socket) do
    expanded = if socket.assigns.expanded_module == module, do: nil, else: module
    {:noreply, assign(socket, expanded_module: expanded)}
  end

  def handle_event("open_root", %{"id" => id}, socket) when is_binary(id),
    do: mutate(socket, &Session.open_root(&1, canonical(socket, id)))

  def handle_event("open_call", %{"card" => card, "target" => target}, socket)
      when is_binary(target),
      do: mutate(socket, &Session.open_child(&1, int(card), canonical(socket, target), target))

  def handle_event("open_caller", %{"card" => card, "caller" => caller}, socket)
      when is_binary(caller) do
    socket = assign(socket, callers_open: nil)
    id = int(card)
    caller_id = canonical(socket, caller)
    target = call_target(socket, caller_id, function_id(socket, id))
    mutate(socket, &Session.open_caller(&1, id, caller_id, target))
  end

  def handle_event("toggle_callers", %{"card" => card}, socket) do
    id = int(card)
    open = if socket.assigns.callers_open == id, do: nil, else: id

    {:noreply, assign(socket, callers_open: open, forest: Session.focus(socket.assigns.name, id))}
  end

  def handle_event("close_card", %{"card" => card}, socket) do
    id = int(card)

    socket =
      if socket.assigns.callers_open == id, do: assign(socket, callers_open: nil), else: socket

    mutate(socket, &Session.close(&1, id))
  end

  def handle_event("close_chain", %{"card" => card}, socket) do
    id = int(card)

    socket =
      if socket.assigns.callers_open == id, do: assign(socket, callers_open: nil), else: socket

    mutate(socket, &Session.close_chain(&1, id))
  end

  def handle_event("focus_card", %{"card" => card}, socket),
    do: mutate(socket, &Session.focus(&1, int(card)))

  def handle_event("toggle_collapse", %{"card" => card}, socket),
    do: mutate(socket, &Session.toggle_collapse(&1, int(card)))

  def handle_event("move_card", %{"card" => card, "dx" => dx, "dy" => dy}, socket) do
    case {int(card), int(dx), int(dy)} do
      {id, dx, dy} when is_integer(id) and is_integer(dx) and is_integer(dy) ->
        mutate(socket, &Session.move(&1, id, {dx, dy}))

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reset_layout", _params, socket),
    do: mutate(socket, &Session.reset_offsets/1)

  def handle_event("toggle_sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_open?, &(not &1))}

  def handle_event("move_focus", %{"dir" => dir}, socket) when dir in ~w(parent child next prev),
    do: mutate(socket, &Session.move_focus(&1, String.to_existing_atom(dir)))

  def handle_event("close_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.close(&1, id))
    end
  end

  def handle_event("close_focused_chain", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.close_chain(&1, id))
    end
  end

  def handle_event("collapse_focused", _params, socket) do
    case socket.assigns.forest.focus do
      nil -> {:noreply, socket}
      id -> mutate(socket, &Session.toggle_collapse(&1, id))
    end
  end

  def handle_event("chat_toggle", _params, socket) do
    {:noreply, socket |> update(:chat_open?, &(not &1)) |> assign(chat_error: nil)}
  end

  def handle_event("chat_send", %{"prompt" => prompt}, socket) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, ask(socket, trimmed)}
    end
  end

  # An empty pick returns to the configured default; anything the facade does not know is
  # ignored rather than reported, since the select cannot offer it.
  def handle_event("chat_model", %{"model" => model}, socket) when is_binary(model) do
    case Grasp.Agent.set_model(socket.assigns.name, if(model == "", do: nil, else: model)) do
      :ok -> {:noreply, refresh_agent(socket)}
      {:error, :unknown_model} -> {:noreply, socket}
    end
  end

  def handle_event("chat_stop", _params, socket) do
    :ok = Grasp.Agent.stop(socket.assigns.name)
    {:noreply, refresh_agent(socket)}
  end

  def handle_event("chat_reset", _params, socket) do
    :ok = Grasp.Agent.reset(socket.assigns.name)
    {:noreply, socket |> assign(chat_error: nil) |> refresh_agent()}
  end

  def handle_event("palette_show", _params, socket),
    do: {:noreply, assign(socket, palette_open?: true, palette_selected: 0, callers_open: nil)}

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

  def handle_event("palette_open", %{"id" => id} = params, socket) when is_binary(id),
    do: open_from_palette(socket, id, child?(params))

  # Events are addressed by name and card id from the DOM, so a stale tab or a hand-made
  # message must be dropped rather than take the whole page down with it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A prompt sent while a run is live is the Send button having been pressed from a stale
  # DOM, where it was still enabled; the panel already says what is happening, so the refusal
  # needs nothing said about it.
  defp ask(socket, prompt) do
    case Grasp.Agent.send_prompt(socket.assigns.name, prompt) do
      :ok -> socket |> assign(chat_error: nil) |> refresh_agent()
      {:error, :running} -> socket
      {:error, :no_command} -> assign(socket, chat_error: @no_command)
    end
  end

  defp refresh_agent(socket), do: assign(socket, agent: Grasp.Agent.get(socket.assigns.name))

  # The form submit carries the query rather than a child flag, so a missing key is a plain
  # root open; the hook sends the boolean and the result buttons the string.
  defp child?(params), do: params["child"] in [true, "true"]

  defp open_from_palette(socket, id, child?) do
    name = socket.assigns.name
    id = canonical(socket, id)

    forest =
      case {child?, socket.assigns.forest.focus} do
        {true, focus} when is_integer(focus) ->
          Session.open_child(name, focus, id, call_target(socket, function_id(socket, focus), id))

        _ ->
          Session.open_root(name, id)
      end

    {:noreply, socket |> assign(forest: forest) |> reset_palette()}
  end

  # The edge an opened card gains is identified by the spelling the caller's own source uses,
  # which is not the callee's id whenever the call goes through a default-argument alias. The
  # palette opens whatever the user picked under whatever has focus, so the two need not be
  # joined by a call at all; nil then leaves the graph to fall back to the callee's id, and the
  # edge simply has no call site in the caller's body to paint.
  defp call_target(socket, caller_function_id, callee_function_id)
       when is_binary(caller_function_id) and is_binary(callee_function_id) do
    case socket.assigns.index do
      %Index{} = index -> Links.call_target(index, caller_function_id, callee_function_id)
      _no_index -> nil
    end
  end

  defp call_target(_socket, _caller_function_id, _callee_function_id), do: nil

  defp function_id(socket, card_id) do
    case Forest.card(socket.assigns.forest, card_id) do
      %{function_id: function_id} -> function_id
      _no_card -> nil
    end
  end

  # A call written against a default-argument alias (`greet/1` for `greet/2`) names a
  # function the index stores under its defining arity; opening the raw id instead would
  # give the same function a second card that no call span can ever mark as open.
  defp canonical(socket, id) do
    case socket.assigns.index && Index.fetch_function(socket.assigns.index, id) do
      {:ok, record} -> record["id"]
      _ -> id
    end
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
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: nil

  @impl true
  def render(%{index: nil} = assigns) do
    ~H"""
    <main class="app app--empty">
      <h1 class="brand">Grasp</h1>
      <p :if={@index_error} class="empty">
        Could not load {@index_path}: {inspect(@index_error)}
      </p>
      <p :if={!@index_error} class="empty">
        No index loaded. Start with <code>mix grasp.serve --index path/to/.grasp/index.json</code>.
      </p>
    </main>
    """
  end

  # Only edges between two visible cards mark a call site: a `data-edge-to` naming a card a
  # collapse has taken off the canvas would point the connector layer at nothing. Grouped once
  # here because `Forest.edges/1` walks the whole graph, and every card would otherwise do so.
  def render(assigns) do
    open_calls =
      assigns.forest
      |> Forest.edges()
      |> Enum.group_by(& &1.from, &{&1.target, %{to: &1.to, color: &1.color}})
      |> Map.new(fn {from, calls} -> {from, Map.new(calls)} end)

    assigns = assign(assigns, open_calls: open_calls)

    ~H"""
    <main
      class={["app", !@sidebar_open? && "app--no-sidebar"]}
      id="app"
      phx-hook="Keys"
      data-sidebar={to_string(@sidebar_open?)}
    >
      <aside :if={@sidebar_open?} class="sidebar">
        <h1 class="brand">Grasp</h1>
        <p class="sidebar__project">{@index.project["app"]}</p>
        <.entry_groups
          index={@index}
          expanded={@expanded_groups}
          expanded_module={@expanded_module}
        />
      </aside>
      <section class="canvas" id="canvas" phx-hook="Canvas">
        <div class="toolbar">
          <button
            type="button"
            id="toggle-sidebar"
            phx-click="toggle_sidebar"
            title="Show or hide the sidebar (⌘M)"
          >
            sidebar
          </button>
          <button type="button" id="zoom-out" title="Zoom out">−</button>
          <span id="zoom-level" class="toolbar__zoom" phx-update="ignore" title="Reset zoom (⌘0)">100%</span>
          <button type="button" id="zoom-fit" title="Fit all cards">fit</button>
          <button type="button" id="zoom-in" title="Zoom in">+</button>
          <button
            type="button"
            id="toggle-chat"
            phx-click="chat_toggle"
            title="Ask the agent (⌘I)"
          >
            ask
          </button>
          <button
            type="button"
            id="reset-layout"
            phx-click="reset_layout"
            title="Return cards to the automatic layout"
          >
            reset layout
          </button>
        </div>
        <p :if={@forest.cards == %{}} class="empty">
          Pick a function from the sidebar or press <kbd>⌘K</kbd>.
        </p>
        <.chat_panel open?={@chat_open?} agent={@agent} error={@chat_error} />
        <div id="stage" class="stage">
          <svg id="connectors" class="connectors" phx-update="ignore" aria-hidden="true">
            <%!-- The hook owns the edge paths, but a marker cannot be built from a path string:
            it has to exist in the document before an edge can point at it. The server renders
            one per palette colour, and the ignored subtree keeps them across every patch. --%>
            <defs>
              <marker
                :for={color <- 0..7}
                id={"arrow-#{color}"}
                viewBox="0 0 10 10"
                refX="9"
                refY="5"
                markerWidth="8"
                markerHeight="8"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" class="arrow" data-color={color} />
              </marker>
            </defs>
            <g id="edges"></g>
          </svg>
          <div class="columns">
            <div :for={{ids, column} <- Enum.with_index(Forest.layout(@forest))} class="column">
              <.card_node
                :for={id <- ids}
                forest={@forest}
                index={@index}
                card_id={id}
                column={column}
                open_calls={Map.get(@open_calls, id, %{})}
                editor={@editor}
                callers_open={@callers_open}
              />
            </div>
          </div>
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
