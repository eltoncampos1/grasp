defmodule Grasp.Session.Disk do
  @moduledoc """
  The file a review session is written to and read back from.

  A session is an arrangement of cards the reviewer built by hand, so it outlives the
  viewer process that drew it: each one is a JSON document under `.grasp/sessions/` in the
  indexed project, named after the session. The directory sits beside the index and the
  comments file, so a session travels with the checkout it describes and can be read like
  any other file in it. `:grasp, :sessions_dir` overrides the directory, and when neither
  that nor a project root on this machine gives one, every call here is a no-op and
  sessions live in memory only — a viewer pointed at an index whose project is not checked
  out still runs, it just forgets.

  A write goes to a temporary file beside the target and is renamed over it, so a crash
  midway through leaves either the previous document or the new one and never half of
  either. A file that does not parse, or that `Grasp.Session.Forest.load/2` refuses, is
  renamed to `<name>.json.corrupt` before the session starts empty: rewriting over it would
  destroy the only copy of an arrangement someone may still want to recover by hand. A
  second damaged file is kept beside the first, under a timestamp, rather than over it.
  """

  require Logger

  alias Grasp.Session.Forest

  @name ~r/^[A-Za-z0-9_-]{1,40}$/

  @doc """
  The directory session files are written to, or nil when they are held in memory only.

  `:grasp, :sessions_dir` wins when it is set; otherwise it is `.grasp/sessions` under the
  root the loaded index names, and nil when that root is not a directory on this machine.
  """
  @spec dir() :: Path.t() | nil
  def dir do
    case Application.get_env(:grasp, :sessions_dir) do
      override when is_binary(override) -> override
      _unset -> derived_dir()
    end
  end

  @doc "The file the session `name` is written to, or nil when there is no directory."
  @spec path(String.t()) :: Path.t() | nil
  def path(name) when is_binary(name) do
    case dir() do
      nil -> nil
      dir -> Path.join(dir, name <> ".json")
    end
  end

  @doc """
  Reads the session `name`, pruning it against `index` as `Forest.load/2` does.

  `:empty` when there is no directory and when the session has no file yet — both mean the
  same thing to a session starting up: begin with an empty graph. A file that cannot be
  decoded is moved aside and `{:error, {:corrupt, moved_to}}` names where it went, leaving
  the caller to say so and start empty.
  """
  @spec read(String.t(), Grasp.Index.t() | nil) :: {:ok, Forest.t()} | :empty | {:error, term()}
  def read(name, index) when is_binary(name) do
    case path(name) do
      nil -> :empty
      path -> read_file(path, index)
    end
  end

  @doc """
  Writes `forest` as the session `name`, replacing whatever was there.

  `:ok` when there is no directory: a viewer with nowhere to write is not a viewer that
  fails to draw.
  """
  @spec write(String.t(), Forest.t()) :: :ok | {:error, term()}
  def write(name, %Forest{} = forest) when is_binary(name) do
    case path(name) do
      nil -> :ok
      path -> write_file(path, Jason.encode!(Forest.dump(forest), pretty: true))
    end
  end

  @doc "Removes the session `name`'s file; a session with no file is already deleted."
  @spec delete(String.t()) :: :ok
  def delete(name) when is_binary(name) do
    case path(name) do
      nil ->
        :ok

      path ->
        File.rm(path)
        :ok
    end
  end

  @doc """
  The names of the saved sessions, sorted.

  A file the viewer could not open again is left out — anything that is not a `.json`
  document under a name `valid_name?/1` accepts, which is what a corrupt file kept aside
  and a temporary file mid-write read as.
  """
  @spec saved() :: [String.t()]
  def saved do
    with dir when is_binary(dir) <- dir(),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&Path.rootname(&1, ".json"))
      |> Enum.filter(&valid_name?/1)
      |> Enum.sort()
    else
      _no_directory -> []
    end
  end

  @doc """
  Whether `name` may name a session: letters, digits, `-` and `_`, up to 40 of them.

  The name is the file name, so what it may hold is what may safely be joined to the
  sessions directory and read back as a name.
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def valid_name?(_name), do: false

  defp derived_dir do
    with %Grasp.Index{} = index <- Grasp.IndexStore.get(),
         root when is_binary(root) <- index.project["root"],
         true <- File.dir?(root) do
      Path.join(root, ".grasp/sessions")
    else
      _no_project_on_disk -> nil
    end
  end

  defp read_file(path, index) do
    case File.read(path) do
      {:ok, binary} -> decode(path, binary, index)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(path, binary, index) do
    with {:ok, document} <- Jason.decode(binary),
         {:ok, forest} <- Forest.load(document, index) do
      {:ok, forest}
    else
      _undecodable -> {:error, {:corrupt, keep_aside(path)}}
    end
  end

  # A second damaged file at the same path is kept beside the first rather than over it:
  # `File.rename/2` replaces an existing destination without a word, and the copy it would
  # replace is the one the reader has not looked at yet.
  defp keep_aside(path) do
    kept = path <> ".corrupt"

    kept =
      if File.exists?(kept),
        do: path <> ".#{System.os_time(:second)}.corrupt",
        else: kept

    case File.rename(path, kept) do
      :ok -> Logger.warning("grasp: kept the unreadable session file as #{kept}")
      {:error, reason} -> Logger.warning("grasp: could not keep #{kept}: #{inspect(reason)}")
    end

    kept
  end

  defp write_file(path, document) do
    temp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, document),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end
end
