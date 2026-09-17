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

  When that move cannot be made — a read-only directory, a name the file system refuses —
  `read/2` says so with `{:error, {:corrupt, path, :not_moved}}` instead of naming a copy
  that is not there, and `Grasp.Session` takes it as the instruction it is: that session
  runs in memory for the rest of its life and writes nothing, because the file it would
  write over is the reviewer's only copy. Putting the directory right and restarting the
  viewer is what brings the session back to disk.

  A session name is the file name, so `path/1` answers nil for a name `valid_name?/1`
  refuses and every call here becomes the no-op it is for a viewer with no directory at
  all: a name that is not a session name reaches no file rather than an unintended one.
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

  @doc """
  The file the session `name` is written to, under `dir` or under the directory `dir/0`
  resolves now.

  Nil when there is no directory, and nil for a name `valid_name?/1` refuses: the name is
  joined to a directory and read back as a name, so one that could name another file names
  no file at all. A caller that holds a directory passes it rather than letting it be
  resolved again, since the answer changes as the index loads.
  """
  @spec path(String.t(), Path.t() | nil) :: Path.t() | nil
  def path(name, dir \\ dir()) when is_binary(name) do
    with true <- valid_name?(name),
         dir when is_binary(dir) <- dir do
      Path.join(dir, name <> ".json")
    else
      _no_file -> nil
    end
  end

  @doc """
  Reads the session `name`, pruning it against `index` as `Forest.load/2` does.

  `:empty` when there is no file to read — no directory, a name that is not a session name,
  or a session that has never been written — which all mean the same thing to a session
  starting up: begin with an empty graph. A file that cannot be decoded is moved aside and
  `{:error, {:corrupt, moved_to}}` names where it went; when the move itself failed,
  `{:error, {:corrupt, path, :not_moved}}` names the file still sitting there, which the
  caller must not write over.
  """
  @spec read(String.t(), Grasp.Index.t() | nil, Path.t() | nil) ::
          {:ok, Forest.t()} | :empty | {:error, term()}
  def read(name, index, dir \\ dir()) when is_binary(name) do
    case path(name, dir) do
      nil -> :empty
      path -> read_file(path, index)
    end
  end

  @doc """
  Writes `forest` as the session `name`, replacing whatever was there.

  `dir` is the directory the caller means, defaulting to the one `dir/0` resolves now; a
  session passes the directory it read from, so a directory that appears under a running
  viewer cannot make it write over a file it never read.

  `:ok` when there is no file to write: a viewer with nowhere to write is not a viewer that
  fails to draw.
  """
  @spec write(String.t(), Forest.t(), Path.t() | nil) :: :ok | {:error, term()}
  def write(name, %Forest{} = forest, dir \\ dir()) when is_binary(name) do
    with path when is_binary(path) <- path(name, dir),
         {:ok, document} <- Jason.encode(Forest.dump(forest), pretty: true) do
      write_file(path, document)
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
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
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def valid_name?(_name), do: false

  @doc """
  The rule `valid_name?/1` applies, as the sentence a refused name is answered with.

  It lives beside the rule so the viewer and the MCP tools refuse a name in the same words:
  a reviewer typing a name into the sidebar and an agent passing one over MCP are being told
  about the same regex.
  """
  @spec name_rule() :: String.t()
  def name_rule, do: "session names are letters, digits, - and _, up to 40 characters"

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
      _undecodable -> corrupt(path)
    end
  end

  # The file is reported as moved only when it moved: a caller told it was kept aside is a
  # caller that will write over the path, and there would be nothing left to recover.
  defp corrupt(path) do
    case keep_aside(path) do
      {:ok, kept} -> {:error, {:corrupt, kept}}
      :error -> {:error, {:corrupt, path, :not_moved}}
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
      :ok ->
        {:ok, kept}

      # The reason the move failed is the one part of this the caller is not handed back.
      {:error, reason} ->
        Logger.warning("grasp: could not keep #{kept}: #{inspect(reason)}")
        :error
    end
  end

  # The temporary file carries a number of its own: two viewers over one checkout would
  # otherwise take turns renaming each other's half-written file over the target.
  defp write_file(path, document) do
    temp = "#{path}.#{System.unique_integer([:positive])}.tmp"

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
