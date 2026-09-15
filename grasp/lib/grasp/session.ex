defmodule Grasp.Session do
  @moduledoc """
  One review session: a named GenServer owning a `Grasp.Session.Forest`.

  The browser and (in a later milestone) the MCP server both mutate a session through this
  API, so state lives here rather than in a LiveView. Every mutation broadcasts
  `{:session, name, forest}` on the `"session:<name>"` topic; subscribers re-render from
  the forest they receive. Sessions are started on demand under `Grasp.SessionSupervisor`
  and found through `Grasp.SessionRegistry`. Persistence to disk arrives in milestone 5.
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

  @doc "Opens a new root card."
  @spec open_root(name(), String.t()) :: Forest.t()
  def open_root(name, function_id), do: mutate(name, &Forest.open_root(&1, function_id))

  @doc """
  Opens (or focuses) `function_id` as a child of `card_id`; `opened_by` records the call
  target that was clicked when it differs from the function's canonical id.
  """
  @spec open_child(name(), Forest.id(), String.t(), String.t() | nil) :: Forest.t()
  def open_child(name, card_id, function_id, opened_by \\ nil),
    do: mutate(name, &Forest.open_child(&1, card_id, function_id, opened_by))

  @doc "Opens `caller_id` as the caller of `card_id`."
  @spec open_caller(name(), Forest.id(), String.t()) :: Forest.t()
  def open_caller(name, card_id, caller_id),
    do: mutate(name, &Forest.open_caller(&1, card_id, caller_id))

  @doc "Closes `card_id` and its subtree."
  @spec close(name(), Forest.id()) :: Forest.t()
  def close(name, card_id), do: mutate(name, &Forest.close(&1, card_id))

  @doc "Focuses `card_id`."
  @spec focus(name(), Forest.id()) :: Forest.t()
  def focus(name, card_id), do: mutate(name, &Forest.focus(&1, card_id))

  @doc "Collapses or expands `card_id`."
  @spec toggle_collapse(name(), Forest.id()) :: Forest.t()
  def toggle_collapse(name, card_id), do: mutate(name, &Forest.toggle_collapse(&1, card_id))

  @doc "Sets `card_id`'s layout offset in stage pixels."
  @spec move(name(), Forest.id(), {integer(), integer()}) :: Forest.t()
  def move(name, card_id, {dx, dy}), do: mutate(name, &Forest.move(&1, card_id, {dx, dy}))

  @doc "Clears every card's offset, returning the tree to its automatic layout."
  @spec reset_offsets(name()) :: Forest.t()
  def reset_offsets(name), do: mutate(name, &Forest.reset_offsets/1)

  @doc "Moves focus in `direction`."
  @spec move_focus(name(), Forest.direction()) :: Forest.t()
  def move_focus(name, direction), do: mutate(name, &Forest.move_focus(&1, direction))

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

    Phoenix.PubSub.broadcast(Grasp.PubSub, topic(state.name), {:session, state.name, forest})
    {:reply, forest, %{state | forest: forest}}
  end

  defp mutate(name, fun), do: GenServer.call(via(name), {:mutate, fun})
  defp via(name), do: {:via, Registry, {Grasp.SessionRegistry, name}}
  defp topic(name), do: "session:" <> name
end
