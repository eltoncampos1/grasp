defmodule Grasp.IndexStore do
  @moduledoc """
  Holds the loaded `Grasp.Index` in `:persistent_term` and reloads it when the index
  file changes.

  The index for a mid-sized project is several megabytes; `:persistent_term` keeps it
  off-heap so every LiveView reads it without copying. The store polls the file's mtime
  every two seconds — `mix grasp.index` rewrites the whole file, so an mtime change is
  the signal — and broadcasts `:index_reloaded` on the `"index"` topic after a successful
  reload. A failed load (missing or invalid file) keeps the previous index and logs.

  The mtime is read *before* the file, so a rewrite landing between the two leaves the
  stored mtime older than the file's and the next poll picks the new content up; reading
  it after would pair the old index with the new mtime and never reload.
  """

  use GenServer
  require Logger

  @key {__MODULE__, :index}
  @topic "index"
  @poll_ms 2_000

  @doc "Starts the store; `:path` defaults to the `:grasp, :index_path` config."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The loaded index, or `nil` when none has been loaded."
  @spec get() :: Grasp.Index.t() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc "The path currently watched, or `nil`."
  @spec path() :: String.t() | nil
  def path, do: GenServer.call(__MODULE__, :path)

  @doc "Loads `path`, replaces the index and starts watching that path."
  @spec load(String.t()) :: :ok | {:error, term()}
  def load(path), do: GenServer.call(__MODULE__, {:load, path})

  @doc "Reloads the watched path now."
  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc "Subscribes the caller to `:index_reloaded` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Application.get_env(:grasp, :index_path))
    state = %{path: nil, mtime: nil}

    state =
      case path && do_load(path, state) do
        {:ok, state} ->
          state

        {:error, reason} ->
          Logger.warning("grasp: could not load index #{path}: #{inspect(reason)}")
          %{state | path: Path.expand(path)}

        nil ->
          state
      end

    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:load, path}, _from, state), do: load_path(path, state)

  def handle_call(:reload, _from, %{path: nil} = state), do: {:reply, {:error, :no_path}, state}
  def handle_call(:reload, _from, state), do: load_path(state.path, state)

  @impl true
  def handle_info(:poll, %{path: nil} = state) do
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    state =
      case File.stat(state.path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime != state.mtime ->
          case do_load(state.path, state) do
            {:ok, state} ->
              state

            {:error, reason} ->
              Logger.warning("grasp: reload failed: #{inspect(reason)}")
              state
          end

        _ ->
          state
      end

    schedule_poll()
    {:noreply, state}
  end

  defp load_path(path, state) do
    case do_load(path, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_load(path, state) do
    # Configuration gives a path relative to the project root; storing it expanded keeps
    # mtime polling and `path/0` independent of the current working directory.
    path = Path.expand(path)

    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, index} <- Grasp.Index.load(path) do
      :persistent_term.put(@key, index)
      Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :index_reloaded)
      {:ok, %{state | path: path, mtime: mtime}}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)
end
