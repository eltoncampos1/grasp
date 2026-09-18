defmodule Mix.Tasks.Grasp.Viewer do
  @shortdoc "Serves the Grasp viewer standalone, for an index file"

  @moduledoc """
  Serves Grasp from an endpoint of its own, for working on Grasp itself.

      mix grasp.viewer --index PATH [--port 4040] [--editor vscode]
                       [--agent-command claude] [--agent-model MODEL]

  Run it from this repository's `grasp/` directory. A project that wants to review its own
  code mounts Grasp in its router instead and reaches it on its own dev server.

  The index is the file `mix grasp.index` wrote in the target project. The viewer binds
  to 127.0.0.1 and reloads the index whenever the file changes. Review comments and saved
  sessions stay with the project being read: the task pins Grasp's home directory to the
  indexed project's root when that root is on this machine, so `.grasp/comments.json` and
  `.grasp/sessions/` are written there and are found again by the next viewer opened on the
  same project, whichever directory it was started from. An index whose project is not
  checked out here falls back to the working directory. `:grasp, :comments_path` and
  `:grasp, :sessions_dir` name other files still.

  ## Options

    * `--index` - path to the index JSON (or set `GRASP_INDEX`). Required.
    * `--port` - HTTP port, default 4040 (or set `GRASP_PORT`).
    * `--editor` - one of `vscode`, `cursor`, `zed` or `idea`; turns `file:line` into a
      deep link (or set `GRASP_EDITOR`). Any other value is rejected.
    * `--agent-command` - the Claude Code CLI the chat panel runs, default `claude` (or
      set `GRASP_AGENT_COMMAND`). A name is looked up on `PATH`; a path is taken as given.
      A value that resolves to no executable is rejected.
    * `--agent-model` - the model that CLI runs with, e.g. a model name or alias it
      accepts (or set `GRASP_AGENT_MODEL`). Omit to leave the CLI on its own default.
  """

  use Mix.Task

  @switches [
    index: :string,
    port: :integer,
    editor: :string,
    agent_command: :string,
    agent_model: :string
  ]
  @editors ~w(vscode cursor zed idea)

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.viewer: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    index =
      opts[:index] || System.get_env("GRASP_INDEX") ||
        Mix.raise("grasp.viewer: --index PATH is required")

    index = Path.expand(index)

    unless File.regular?(index), do: Mix.raise("grasp.viewer: no such file #{index}")

    editor = opts[:editor]

    if editor && editor not in @editors do
      Mix.raise("grasp.viewer: --editor must be one of #{Enum.join(@editors, ", ")}")
    end

    agent_command = opts[:agent_command]

    if agent_command && is_nil(System.find_executable(agent_command)) do
      Mix.raise("grasp.viewer: --agent-command #{agent_command} is not an executable")
    end

    agent_model = opts[:agent_model]

    if agent_model == "" do
      Mix.raise("grasp.viewer: --agent-model must name a model")
    end

    # The store loads the index again at boot; one extra decode buys a readable error here
    # instead of a viewer that comes up empty and explains nothing.
    loaded =
      case Grasp.Index.load(index) do
        {:ok, loaded} -> loaded
        {:error, reason} -> Mix.raise("grasp.viewer: cannot read #{index}: #{inspect(reason)}")
      end

    # Recorded before the application starts, which is what reads it.
    Application.put_env(:grasp, :home, home(loaded), persistent: true)

    System.put_env("GRASP_INDEX", index)
    if opts[:port], do: System.put_env("GRASP_PORT", Integer.to_string(opts[:port]))
    if editor, do: System.put_env("GRASP_EDITOR", editor)
    if agent_command, do: System.put_env("GRASP_AGENT_COMMAND", agent_command)
    if agent_model, do: System.put_env("GRASP_AGENT_MODEL", agent_model)

    # The viewer serves its own endpoint; mounted in a host application Grasp serves none.
    Application.put_env(:grasp, :standalone, true, persistent: true)
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.shell().info("Grasp viewer: http://127.0.0.1:#{opts[:port] || 4040}  (index: #{index})")
    Mix.Task.run("run", ["--no-halt"])
  end

  @doc """
  The directory this viewer keeps comments and sessions in for `index`.

  The indexed project's root, so a review stays with the code it is about rather than with
  the directory the viewer happened to be started from — `mix grasp.viewer` is run from
  Grasp's own checkout, which is nobody's review. A root that is not a directory on this
  machine leaves the working directory, where the files at least have somewhere to go.
  """
  @spec home(Grasp.Index.t()) :: Path.t()
  def home(%Grasp.Index{} = index) do
    root = index.project["root"]

    if is_binary(root) and File.dir?(root), do: Path.expand(root), else: File.cwd!()
  end
end
