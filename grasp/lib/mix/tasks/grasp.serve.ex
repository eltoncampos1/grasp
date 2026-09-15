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
    * `--editor` - `vscode`, `cursor`, `zed` or `idea`; turns `file:line` into a deep link.
  """

  use Mix.Task

  @switches [index: :string, port: :integer, editor: :string]

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

    System.put_env("GRASP_INDEX", index)
    if opts[:port], do: System.put_env("GRASP_PORT", Integer.to_string(opts[:port]))
    if opts[:editor], do: System.put_env("GRASP_EDITOR", opts[:editor])

    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.shell().info("Grasp viewer: http://127.0.0.1:#{opts[:port] || 4040}  (index: #{index})")
    Mix.Task.run("run", ["--no-halt"])
  end
end
