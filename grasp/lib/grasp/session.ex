defmodule Grasp.Session do
  @moduledoc """
  One review session: a named GenServer owning a `Grasp.Session.Forest`.

  The browser and the MCP server both mutate a session through this API, so state lives
  here rather than in a LiveView. Every mutation broadcasts `{:session, name, forest}` on
  the `"session:<name>"` topic; subscribers re-render from the forest they receive.
  Sessions are started on demand under `Grasp.SessionSupervisor` and found through
  `Grasp.SessionRegistry`, and they are held in memory only: a session is gone when the
  viewer stops.
  """

  use GenServer

  alias Grasp.Session.Forest

  @type name :: String.t()

  @doc "Starts the session named `name` if it is not running."
  @spec ensure(name()) :: :ok
  def ensure(name) do
    case DynamicSupervisor.start_child(Grasp.SessionSupervisor, {__MODULE__, name}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def child_spec(name),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  @doc "Subscribes the caller to `{:session, name, forest}` broadcasts."
  @spec subscribe(name()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(Grasp.PubSub, topic(name))

  @doc "The current forest."
  @spec get(name()) :: Forest.t()
  def get(name), do: GenServer.call(via(name), :get)

  @doc "Opens `function_id` with no caller, or focuses the card already showing it."
  @spec open_root(name(), String.t()) :: Forest.t()
  def open_root(name, function_id), do: mutate(name, &Forest.open_root(&1, function_id))

  @doc """
  Opens (or focuses) `function_id` as a callee of `card_id`; `opened_by` records the call
  target that was clicked when it differs from the function's canonical id.
  """
  @spec open_child(name(), Forest.id(), String.t(), String.t() | nil) :: Forest.t()
  def open_child(name, card_id, function_id, opened_by \\ nil),
    do: mutate(name, &Forest.open_child(&1, card_id, function_id, opened_by))

  @doc """
  Opens (or focuses) `caller_id` as a caller of `card_id`; `target` records the call target
  the caller writes when it differs from the card's canonical id.
  """
  @spec open_caller(name(), Forest.id(), String.t(), String.t() | nil) :: Forest.t()
  def open_caller(name, card_id, caller_id, target \\ nil),
    do: mutate(name, &Forest.open_caller(&1, card_id, caller_id, target))

  @doc "Closes `card_id` alone, leaving the cards it called behind."
  @spec close(name(), Forest.id()) :: Forest.t()
  def close(name, card_id), do: mutate(name, &Forest.close(&1, card_id))

  @doc "Closes `card_id` and every card that had no other way to be reached."
  @spec close_chain(name(), Forest.id()) :: Forest.t()
  def close_chain(name, card_id), do: mutate(name, &Forest.close_chain(&1, card_id))

  @doc "Focuses `card_id`."
  @spec focus(name(), Forest.id()) :: Forest.t()
  def focus(name, card_id), do: mutate(name, &Forest.focus(&1, card_id))

  @doc "Collapses or expands `card_id`, hiding or showing what only it reaches."
  @spec toggle_collapse(name(), Forest.id()) :: Forest.t()
  def toggle_collapse(name, card_id), do: mutate(name, &Forest.toggle_collapse(&1, card_id))

  @doc "Shows `card_id` as its source or as its diff against the base."
  @spec set_view(name(), Forest.id(), Forest.view()) :: Forest.t()
  def set_view(name, card_id, view), do: mutate(name, &Forest.set_view(&1, card_id, view))

  @doc "Swaps `card_id` between its source and its diff."
  @spec toggle_view(name(), Forest.id()) :: Forest.t()
  def toggle_view(name, card_id), do: mutate(name, &Forest.toggle_view(&1, card_id))

  @doc "Shows `card_id`'s diff as the changed hunks alone or as every line."
  @spec set_context(name(), Forest.id(), Forest.context()) :: Forest.t()
  def set_context(name, card_id, context),
    do: mutate(name, &Forest.set_context(&1, card_id, context))

  @doc "Swaps `card_id` between the changes alone and every line; `loc` is the function's length."
  @spec toggle_context(name(), Forest.id(), non_neg_integer()) :: Forest.t()
  def toggle_context(name, card_id, loc),
    do: mutate(name, &Forest.toggle_context(&1, card_id, loc))

  @doc "Sets `card_id`'s layout offset in stage pixels."
  @spec move(name(), Forest.id(), {integer(), integer()}) :: Forest.t()
  def move(name, card_id, {dx, dy}), do: mutate(name, &Forest.move(&1, card_id, {dx, dy}))

  @doc """
  Adds `{dx, dy}` to the layout offset of every card in `group_id`, moving the group as one.
  An unknown group changes nothing.
  """
  @spec shift_group(name(), Forest.group_id(), {integer(), integer()}) :: Forest.t()
  def shift_group(name, group_id, {dx, dy}) when is_integer(dx) and is_integer(dy),
    do: mutate(name, &Forest.shift_group(&1, group_id, {dx, dy}))

  @doc "Clears every card's offset, returning the cards to their automatic layout."
  @spec reset_offsets(name()) :: Forest.t()
  def reset_offsets(name), do: mutate(name, &Forest.reset_offsets/1)

  @doc """
  Puts `card_ids` into a group of their own, titled `title` or untitled when that is nil or
  blank. The group is always a new one, so two may share a title; each card leaves whatever
  group it was in, and a group left with no members is gone.
  """
  @spec new_group(name(), String.t() | nil, [Forest.id()]) :: Forest.t()
  def new_group(name, title, card_ids),
    do: mutate(name, &Forest.new_group(&1, title, card_ids))

  @doc """
  Puts `card_ids` into the group titled `title`, creating it when nothing carries that title
  yet. Each card leaves whatever group it was in, and a group left with no members is gone.
  """
  @spec group_cards(name(), String.t(), [Forest.id()]) :: Forest.t()
  def group_cards(name, title, card_ids),
    do: mutate(name, &Forest.group_cards(&1, title, card_ids))

  @doc "Takes `card_ids` out of their groups, deleting a group left with no members."
  @spec ungroup_cards(name(), [Forest.id()]) :: Forest.t()
  def ungroup_cards(name, card_ids), do: mutate(name, &Forest.ungroup_cards(&1, card_ids))

  @doc """
  Retitles `group_id`, keeping its cards. A blank or nil title leaves the group untitled;
  an unknown group changes nothing.
  """
  @spec rename_group(name(), Forest.group_id(), String.t() | nil) :: Forest.t()
  def rename_group(name, group_id, title),
    do: mutate(name, &Forest.rename_group(&1, group_id, title))

  @doc """
  Puts `card_ids` into the existing group `group_id`, out of whatever group they were in. An
  unknown group changes nothing, and a group left with no members is deleted.
  """
  @spec add_to_group(name(), Forest.group_id(), [Forest.id()]) :: Forest.t()
  def add_to_group(name, group_id, card_ids),
    do: mutate(name, &Forest.add_to_group(&1, group_id, card_ids))

  @doc "Deletes `group_id`, leaving its cards in the graph with no group."
  @spec dissolve_group(name(), Forest.group_id()) :: Forest.t()
  def dissolve_group(name, group_id), do: mutate(name, &Forest.dissolve_group(&1, group_id))

  @doc "Moves focus in `direction`."
  @spec move_focus(name(), Forest.direction()) :: Forest.t()
  def move_focus(name, direction), do: mutate(name, &Forest.move_focus(&1, direction))

  @doc """
  Replaces the whole graph with the cards `specs` describes. The session keeps its current
  forest, and nothing is broadcast, when the spec does not build.
  """
  @spec set_cards(name(), [Forest.spec()]) :: {:ok, Forest.t()} | {:error, term()}
  def set_cards(name, specs), do: GenServer.call(via(name), {:replace, specs})

  @doc "Sets what `card_id` points at: a call, a line range, or nothing."
  @spec set_highlight(name(), Forest.id(), Forest.highlight()) :: Forest.t()
  def set_highlight(name, card_id, highlight),
    do: mutate(name, &Forest.set_highlight(&1, card_id, highlight))

  @doc "Names of the sessions currently running, sorted."
  @spec list() :: [String.t()]
  def list do
    Grasp.SessionRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  @impl true
  def init(name), do: {:ok, %{name: name, forest: Forest.new()}}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.forest, state}

  def handle_call({:mutate, fun}, _from, state) do
    forest =
      case fun.(state.forest) do
        {%Forest{} = forest, _id} -> forest
        %Forest{} = forest -> forest
      end

    broadcast(state.name, forest)
    {:reply, forest, %{state | forest: forest}}
  end

  def handle_call({:replace, specs}, _from, state) do
    case Forest.replace(specs) do
      {:ok, forest} ->
        broadcast(state.name, forest)
        {:reply, {:ok, forest}, %{state | forest: forest}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp broadcast(name, forest),
    do: Phoenix.PubSub.broadcast(Grasp.PubSub, topic(name), {:session, name, forest})

  defp mutate(name, fun), do: GenServer.call(via(name), {:mutate, fun})
  defp via(name), do: {:via, Registry, {Grasp.SessionRegistry, name}}
  defp topic(name), do: "session:" <> name
end
