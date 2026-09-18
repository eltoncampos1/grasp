defmodule Grasp.Reindexer do
  @moduledoc """
  Keeps the index following the host's saves by riding its code reloader.

  Phoenix's code reloader compiles in the endpoint's own VM — its server process calls
  `Mix.Task.run("compile.elixir", …)` there — and `mix compile.elixir` appends
  whatever `Code.get_compiler_option(:tracers)` holds to the tracers it was given. So
  installing `Grasp.Index.Tracer` into this VM's compiler options once, at startup, is
  enough for every incremental compile that follows a save to report its calls to Grasp.

  The tracer sends `{:events, count}` as it records. Each message pushes the flush 300 ms
  further out, so a compile that takes two seconds is followed by one update rather than by
  one per file; the flush then drains the whole event table at once.

  An update reads the index document from the store's path, works out which project files
  the events name, hands them to `Grasp.Index.Incremental`, writes the document back
  through a temporary file in the same directory and renames it into place — a reader
  polling the path sees the old document or the new one, never half of one — and asks
  `Grasp.IndexStore` to reload.

  Four rules keep the process honest about what it may touch.

    * **The batch is held until the update lands.** A drained event table cannot be drained
      again, so the batch stays in the process's state until an update has written it, and
      a flush that fails — an error, an exception, a store call that timed out — leaves it
      there for the next one to pick up.
    * **An event older than its file is dropped.** The events were recorded by a compile
      that has finished; a save that landed after it leaves the file with an mtime the
      event predates, and joining the two would place calls on lines that have moved.
    * **A whole recompile is not an update.** More than fifty project files in one batch is
      a rebuild rather than a save; the reindexer says so and leaves the index to
      `mix grasp.index`, rather than shelling out to git once per file inside one callback.
    * **Only the reader's own tree is followed.** `mix grasp.pr` writes an index whose
      `project.root` is a worktree, and the host's compiles say nothing about that tree, so
      a document rooted anywhere but Grasp's home directory pauses live reindexing until an
      index of the host's own tree is loaded again.

  Nothing here may take the host down with it. A flush that fails is logged and the next
  save tries again; a project with no index yet is not an error, it is a project whose
  reader has not run `mix grasp.index` at all, and the flush does nothing until the file
  appears.

  Grasp does not start this process when it is serving standalone: `mix grasp.viewer` has
  no host compiling anything to follow.
  """

  use GenServer

  require Logger

  alias Grasp.Index.{Incremental, Tracer}

  @flush_ms 300
  @max_files 50
  # The store decodes a multi-megabyte document inside its own callback, and a call made
  # while one is in flight waits for it. Waiting is right here; timing out would throw away
  # an update that had already been written.
  @store_timeout :timer.seconds(30)

  @doc """
  Starts the reindexer and installs the tracer.

  `:index_path` overrides the document to update, which otherwise follows
  `Grasp.IndexStore.path/1`; `:flush_ms` overrides the quiet window. The process is always
  registered under its own module name, because that is the name the tracer looks it up
  under.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The quiet window, in milliseconds, between the last traced call and an update."
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: @flush_ms

  @impl true
  def init(opts) do
    Tracer.start()
    Tracer.install()

    {:ok,
     %{
       index_path: Keyword.get(opts, :index_path),
       flush_ms: Keyword.get(opts, :flush_ms, @flush_ms),
       timer: nil,
       generation: 0,
       pending: [],
       paused: nil
     }}
  end

  @impl true
  def handle_info({:events, _count}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    generation = state.generation + 1

    {:noreply,
     %{
       state
       | generation: generation,
         timer: Process.send_after(self(), {:flush, generation}, state.flush_ms)
     }}
  end

  def handle_info({:flush, generation}, %{generation: generation} = state) do
    state = %{state | timer: nil, pending: state.pending ++ Tracer.take_events()}

    try do
      case flush(state) do
        {:ok, state} -> {:noreply, %{state | pending: []}}
        {:error, reason} -> {:noreply, warn(state, reason)}
      end
    rescue
      error -> {:noreply, warn(state, error)}
    catch
      :exit, reason -> {:noreply, warn(state, {:exit, reason})}
    end
  end

  # A timer cancelled by a later event may already have landed in the mailbox; the
  # generation it was scheduled under is what tells it from the one still to come.
  def handle_info({:flush, _superseded}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp flush(%{pending: []} = state), do: {:ok, state}

  defp flush(state) do
    path = index_path(state)

    case read_document(path) do
      {:ok, document} ->
        update(document, state, path)

      # A project whose reader has not built an index yet has nothing to update, and the
      # build that writes the first one reads the whole project anyway.
      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update(%{"project" => %{"root" => root}} = document, state, path) when is_binary(root) do
    if own_tree?(root) do
      paths = document["project"]["elixirc_paths"] || ["lib"]
      events = state.pending |> project_events(root, paths) |> drop_stale(root)
      changed = events |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort()
      state = %{state | paused: nil}

      cond do
        changed == [] -> {:ok, state}
        length(changed) > @max_files -> {:ok, too_many(changed, state)}
        true -> rewrite(document, root, changed, events, paths, path, state)
      end
    else
      {:ok, pause(state, root)}
    end
  end

  defp update(_document, _state, _path), do: {:error, :no_project_root}

  defp rewrite(document, root, changed, events, paths, path, state) do
    with {:ok, updated} <-
           Incremental.update(
             document,
             root,
             changed,
             events,
             base_context(document, root, paths)
           ),
         :ok <- write(path, Jason.encode!(updated, pretty: true)) do
      Grasp.IndexStore.reload(@store_timeout)
      {:ok, state}
    end
  end

  # The comparison is between expanded paths, because a document written by a task that ran
  # somewhere else names its root absolutely and Grasp's home is whatever directory the
  # host's server was started from.
  defp own_tree?(root) do
    home = Grasp.Application.home() || File.cwd!()
    Path.expand(root) == Path.expand(home)
  end

  defp pause(state, root) do
    if state.paused != root do
      Logger.info(
        "grasp: the loaded index describes #{root}; live reindexing is paused until an " <>
          "index of this project is loaded again"
      )
    end

    %{state | paused: root}
  end

  defp too_many(changed, state) do
    Logger.info(
      "grasp: #{length(changed)} files compiled at once, which is a rebuild rather than a " <>
        "save; run `mix grasp.index` to bring the index up to date"
    )

    state
  end

  # An event's file is whatever the compiler saw; only the ones under the indexed project
  # describe code this document holds, and they are named the way the document names them.
  defp project_events(events, root, paths) do
    roots = Enum.map(paths, &(Path.expand(&1, root) <> "/"))

    events
    |> Enum.map(&%{&1 | file: Path.expand(&1.file, root)})
    |> Enum.filter(fn event -> Enum.any?(roots, &String.starts_with?(event.file, &1)) end)
    |> Enum.map(&%{&1 | file: Path.relative_to(&1.file, root)})
  end

  # The mtime is read now rather than when the batch was drained, so a batch kept for a
  # retry is measured against the file as it stands, not as it stood when the flush that
  # failed looked at it. An event stamped in the same second as the save survives: the
  # filesystem's second is as fine as the stamp.
  defp drop_stale(events, root) do
    mtimes =
      events
      |> Enum.map(& &1.file)
      |> Enum.uniq()
      |> Map.new(&{&1, mtime(Path.join(root, &1))})

    Enum.filter(events, fn event ->
      case Map.get(mtimes, event.file) do
        nil -> true
        mtime -> Map.get(event, :at, mtime) >= mtime
      end
    end)
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> nil
    end
  end

  defp base_context(document, root, paths) do
    case document["git"] do
      %{"base_sha" => sha} when is_binary(sha) -> %{root: root, base_sha: sha, paths: paths}
      _no_base -> nil
    end
  end

  defp index_path(%{index_path: nil}), do: Grasp.IndexStore.path(@store_timeout)
  defp index_path(%{index_path: path}), do: path

  defp read_document(path) do
    with {:ok, binary} <- File.read(path), do: Jason.decode(binary)
  end

  # Written beside the index and renamed over it: a rename within a directory is atomic, so
  # the store's poll never reads a document that is half written.
  defp write(path, json) do
    temporary = path <> ".tmp"

    with :ok <- File.write(temporary, json),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp warn(state, reason) do
    Logger.warning("grasp: could not update the index: #{inspect(reason)}")
    state
  end
end
