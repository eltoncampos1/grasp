defmodule Mix.Tasks.Grasp.Serve do
  @shortdoc "Serves the Grasp viewer for an index file"

  @moduledoc """
  Starts the Grasp viewer.

      mix grasp.serve --index PATH [--port 4040] [--editor vscode]

  The index is the file `mix grasp.index` wrote in the target project. The viewer binds
  to 127.0.0.1 and reloads the index whenever the file changes.

  ## Options

    * `--index` - path to the index JSON (or set `GRASP_INDEX`). Required.
    * `--port` - HTTP port, default 4040.
    * `--editor` - one of `vscode`, `cursor`, `zed` or `idea`; turns `file:line` into a
      deep link. Any other value is rejected.
  """

  use Mix.Task

  @switches [index: :string, port: :integer, editor: :string]
  @editors ~w(vscode cursor zed idea)

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.serve: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    index =
      opts[:index] || System.get_env("GRASP_INDEX") ||
        Mix.raise("grasp.serve: --index PATH is required")

    index = Path.expand(index)

    unless File.regular?(index), do: Mix.raise("grasp.serve: no such file #{index}")

    editor = opts[:editor]

    if editor && editor not in @editors do
      Mix.raise("grasp.serve: --editor must be one of #{Enum.join(@editors, ", ")}")
    end

    # The store loads the index again at boot; one extra decode buys a readable error here
    # instead of a viewer that comes up empty and explains nothing.
    case Grasp.Index.load(index) do
      {:ok, _index} -> :ok
      {:error, reason} -> Mix.raise("grasp.serve: cannot read #{index}: #{inspect(reason)}")
    end

    System.put_env("GRASP_INDEX", index)
    if opts[:port], do: System.put_env("GRASP_PORT", Integer.to_string(opts[:port]))
    if editor, do: System.put_env("GRASP_EDITOR", editor)

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.shell().info("Grasp viewer: http://127.0.0.1:#{opts[:port] || 4040}  (index: #{index})")
    Mix.Task.run("run", ["--no-halt"])
  end
end
