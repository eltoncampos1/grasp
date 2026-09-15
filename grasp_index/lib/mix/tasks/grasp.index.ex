defmodule Mix.Tasks.Grasp.Index do
  @shortdoc "Writes a Grasp index of this project to .grasp/index.json"

  @moduledoc """
  Builds the Grasp index for the current Mix project.

      mix grasp.index [--out PATH]

  Forces a full recompile with a compiler tracer attached, so every call the compiler
  resolves is recorded with its position, then writes the JSON document the Grasp viewer
  and MCP server read.

  The index is built from what the compiler resolves, so a project that fails to compile
  aborts the task with the compiler's own error. A single file that cannot be read or
  parsed is reported and skipped; only its definitions are missing from the index.

  ## Options

    * `--out` - where to write the index. Defaults to `.grasp/index.json`.
  """

  use Mix.Task

  @switches [out: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("grasp.index: unknown options #{inspect(Enum.map(invalid, &elem(&1, 0)))}")
    end

    {:ok, summary} = Grasp.Index.Builder.run(opts)

    Mix.shell().info(
      "Grasp index written to #{summary.path} " <>
        "(#{summary.functions} functions, #{summary.calls} calls, #{summary.hidden_calls} hidden)"
    )
  end
end
