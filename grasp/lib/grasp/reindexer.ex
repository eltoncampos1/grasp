defmodule Grasp.Reindexer do
  @moduledoc """
  Keeps the index following the host's saves by riding its code reloader.

  Phoenix's code reloader compiles in the endpoint's own VM — its server process calls
  `Mix.Task.run("compile.elixir", …)` there — and `mix compile.elixir` appends
  whatever `Code.get_compiler_option(:tracers)` holds to the tracers it was given. So
  installing `Grasp.Index.Tracer` into this VM's compiler options once, at startup, is
  enough for every incremental compile that follows a save to report its calls to Grasp.
  `parser_options: [columns: true]` goes in beside it, because a call without a column
  cannot be placed inside the definition that makes it.

  The tracer sends `{:events, count}` as it records. Each message pushes the flush 300 ms
  further out, so a compile that takes two seconds is followed by one update rather than by
  one per file; the flush then drains the whole event table at once.

  An update reads the index document from the store's path, works out which project files
  the events name, hands them to `Grasp.Index.Incremental`, writes the document back
  through a temporary file in the same directory and renames it into place — a reader
  polling the path sees the old document or the new one, never half of one — and asks
  `Grasp.IndexStore` to reload.

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

  @doc """
  Starts the reindexer and installs the tracer.

  `:index_path` overrides the document to update, which otherwise follows
  `Grasp.IndexStore.path/0`; `:flush_ms` overrides the quiet window; `:name` the
  registered name, which the tracer looks the process up under.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The quiet window, in milliseconds, between the last traced call and an update."
  @spec flush_ms() :: pos_integer()
  def flush_ms, do: @flush_ms

  @impl true
  def init(opts) do
    Tracer.start()
    install_tracer()

    {:ok,
     %{
       index_path: Keyword.get(opts, :index_path),
       flush_ms: Keyword.get(opts, :flush_ms, @flush_ms),
       timer: nil
     }}
  end

  @impl true
  def handle_info({:events, _count}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :flush, state.flush_ms)}}
  end

  def handle_info(:flush, state) do
    case flush(state) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("grasp: could not update the index: #{inspect(reason)}")
    end

    {:noreply, %{state | timer: nil}}
  rescue
    error ->
      Logger.warning("grasp: could not update the index: #{Exception.message(error)}")
      {:noreply, %{state | timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The tracer is prepended rather than assigned, so a host that installs a tracer of its
  # own keeps it, and installing twice does not double every event.
  defp install_tracer do
    tracers = Code.get_compiler_option(:tracers)
    unless Tracer in tracers, do: Code.put_compiler_option(:tracers, [Tracer | tracers])

    parser = Code.get_compiler_option(:parser_options)

    unless Keyword.get(parser, :columns) do
      Code.put_compiler_option(:parser_options, Keyword.put(parser, :columns, true))
    end

    :ok
  end

  defp flush(state) do
    case Tracer.take_events() do
      [] ->
        :ok

      events ->
        path = index_path(state)

        case read_document(path) do
          {:ok, document} -> update(document, events, path)
          # A project whose reader has not built an index yet has nothing to update.
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp update(%{"project" => %{"root" => root}} = document, events, path) when is_binary(root) do
    paths = document["project"]["elixirc_paths"] || ["lib"]
    events = project_events(events, root, paths)
    changed = events |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort()

    if changed == [] do
      :ok
    else
      case Incremental.update(
             document,
             root,
             changed,
             events,
             base_context(document, root, paths)
           ) do
        {:ok, document} ->
          with :ok <- write(path, Jason.encode!(document, pretty: true)) do
            Grasp.IndexStore.reload()
            :ok
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
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

  defp base_context(document, root, paths) do
    case document["git"] do
      %{"base_sha" => sha} when is_binary(sha) -> %{root: root, base_sha: sha, paths: paths}
      _no_base -> nil
    end
  end

  defp index_path(%{index_path: nil}), do: Grasp.IndexStore.path()
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
end
