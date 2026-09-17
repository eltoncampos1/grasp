defmodule Mix.Tasks.Grasp.Serve do
  @shortdoc "Runs the Grasp viewer against this project's index"

  @moduledoc """
  Runs the Grasp viewer against the index of the current project.

      mix grasp.serve [--index PATH] [--viewer PATH] [--repo URL]
                      [--port 4040] [--editor vscode]
                      [--agent-command claude] [--agent-model MODEL]

  The viewer is a Phoenix application and is never a dependency of the project it reviews,
  so it runs from a checkout of the Grasp repository: `--viewer PATH`, else `GRASP_VIEWER`,
  else `~/.grasp/viewer`, and the current directory when the current project is the viewer
  itself. A checkout that is not there yet is cloned from `--repo URL`, else
  `GRASP_VIEWER_REPO`, else the repository on GitHub; a checkout without its dependencies
  or its built assets gets them before the viewer starts. Those are one-off waits on a new
  machine.

  The viewer runs as a child process and its output arrives here. It has a process group of
  its own, out of reach of a terminal interrupt, so it is tied to this task instead: it is
  stopped whenever this task's VM goes, whether that is a SIGTERM, a break the runtime
  answered by aborting, or a crash. Ctrl-C raises the runtime's break menu; abort there and
  the viewer goes too, leaving the port free for the next run.

  ## Options

    * `--index` - path to the index JSON, default `.grasp/index.json`. `mix grasp.index`
      writes it, and it has to exist.
    * `--viewer` - the checkout to run the viewer from.
    * `--repo` - the repository a missing checkout is cloned from.
    * `--port` - HTTP port, default 4040.
    * `--editor` - one of `vscode`, `cursor`, `zed` or `idea`; turns `file:line` into a
      deep link.
    * `--agent-command` - the Claude Code CLI the chat panel runs, default `claude`.
    * `--agent-model` - the model that CLI runs with. Omit to leave the CLI on its own
      default.

  Everything from `--port` on is passed to the viewer, which is what validates it.
  """

  use Mix.Task

  alias Grasp.Index.Viewer

  @switches [
    index: :string,
    viewer: :string,
    repo: :string,
    port: :integer,
    editor: :string,
    agent_command: :string,
    agent_model: :string
  ]

  @forwarded [:port, :editor, :agent_command, :agent_model]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.serve: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    index = Path.expand(opts[:index] || ".grasp/index.json")

    unless File.regular?(index) do
      Mix.raise("grasp.serve: no index at #{index} — run mix grasp.index first")
    end

    repo = opts[:repo] || System.get_env("GRASP_VIEWER_REPO") || Viewer.default_repo()

    checkout =
      Viewer.checkout(
        viewer: opts[:viewer],
        env: System.get_env(),
        cwd: File.cwd!(),
        cwd_app: Mix.Project.config()[:app]
      )

    argv = ["--index", index | OptionParser.to_argv(Keyword.take(opts, @forwarded))]
    runner = Application.get_env(:grasp_index, :viewer_runner, &Viewer.shell/2)
    steps = Viewer.steps(checkout, repo, argv)

    # Each line is printed as its step starts rather than all of them up front, so a first run
    # that clones and builds says what it is waiting on while it waits.
    case Viewer.run(steps, runner, &Mix.shell().info(announce(&1))) do
      :ok -> :ok
      {:error, message} -> Mix.raise("grasp.serve: #{message}")
    end
  end

  defp announce({:clone, _url, into}), do: "Cloning the Grasp viewer into #{into}"
  defp announce({:deps, _project}), do: "Fetching the viewer's dependencies…"
  defp announce({:assets, _project}), do: "Building the viewer's assets…"
  defp announce({:serve, project, _argv}), do: "Starting the viewer from #{project}"
end
