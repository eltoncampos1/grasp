defmodule Mix.Tasks.Grasp.Viewer do
  @shortdoc "Serves the Grasp viewer standalone, for an index file"

  @moduledoc """
  Serves Grasp from an endpoint of its own, for working on Grasp itself.

      mix grasp.viewer --index PATH [--port 4040] [--editor vscode]
                       [--agent-command claude] [--agent-model MODEL]

  Run it from this repository's `grasp/` directory. A project that wants to review its own
  code mounts Grasp in its router instead and reaches it on its own dev server.

  The index is the file `mix grasp.index` wrote in the target project. The viewer binds
  to 127.0.0.1 and reloads the index whenever the file changes. Review comments live
  beside it, in `.grasp/comments.json` under the indexed project's root, and are read on
  boot and rewritten after every change so they persist across restarts.

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
    case Grasp.Index.load(index) do
      {:ok, _index} -> :ok
      {:error, reason} -> Mix.raise("grasp.viewer: cannot read #{index}: #{inspect(reason)}")
    end

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
end
