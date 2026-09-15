defmodule Grasp.Index.Builder do
  @moduledoc """
  Builds the index for the Mix project in the current directory and writes it as JSON.

  Runs inside the target project's Mix session (`mix grasp.index`), where the compiler,
  the project configuration and the compiled code are all at hand. It registers
  `Grasp.Index.Tracer`, forces a full recompile so every call in the project is traced
  (dependencies are compiled only if stale and filtered out by path), extracts
  definitions from every `.ex` file under `:elixirc_paths`, joins the two and writes the
  document `Grasp.Index.load/1` reads. Git metadata is best-effort: `nil` when the
  project is not in a repository or `git` is not installed.
  """

  alias Grasp.Index.{Extract, Join, Tracer}

  @type summary :: %{
          path: String.t(),
          functions: non_neg_integer(),
          calls: non_neg_integer(),
          hidden_calls: non_neg_integer()
        }

  @doc "Traces, extracts, joins and writes the index. `:out` defaults to `.grasp/index.json`."
  @spec run(out: String.t()) :: {:ok, summary()}
  def run(opts) do
    out = Keyword.get(opts, :out, ".grasp/index.json")
    config = Mix.Project.config()
    root = File.cwd!()
    paths = Keyword.get(config, :elixirc_paths, ["lib"])

    events = trace_compile(root, paths)
    {definitions, modules} = extract_all(root, paths)
    functions = Join.join(definitions, events)

    document = %{
      "version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "project" => %{"app" => to_string(config[:app]), "root" => root, "elixirc_paths" => paths},
      "git" => git_info(root),
      "modules" => Enum.map(modules, &%{"name" => &1.name, "file" => &1.file, "line" => &1.line}),
      "functions" => Enum.map(functions, &function_json/1),
      "entry_points" => []
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Jason.encode!(document, pretty: true))

    {:ok,
     %{
       path: out,
       functions: length(functions),
       calls: functions |> Enum.map(&length(&1.calls)) |> Enum.sum(),
       hidden_calls: functions |> Enum.map(&length(&1.hidden_calls)) |> Enum.sum()
     }}
  end

  defp trace_compile(root, paths) do
    previous_tracers = Code.get_compiler_option(:tracers)
    previous_parser = Code.get_compiler_option(:parser_options)
    Tracer.start()
    Code.put_compiler_option(:tracers, [Tracer | previous_tracers])
    Code.put_compiler_option(:parser_options, Keyword.put(previous_parser, :columns, true))

    try do
      Mix.Task.rerun("compile", ["--force"])
      roots = Enum.map(paths, &(Path.expand(&1, root) <> "/"))

      Tracer.events()
      |> Enum.map(&%{&1 | file: Path.expand(&1.file, root)})
      |> Enum.filter(fn event -> Enum.any?(roots, &String.starts_with?(event.file, &1)) end)
      |> Enum.map(&%{&1 | file: Path.relative_to(&1.file, root)})
    after
      Code.put_compiler_option(:tracers, previous_tracers)
      Code.put_compiler_option(:parser_options, previous_parser)
      Tracer.stop()
    end
  end

  defp extract_all(root, paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**", "*.ex"])))
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn file, {definitions, modules} ->
      relative = Path.relative_to(file, root)

      case Extract.extract(File.read!(file), relative) do
        {:ok, extracted} ->
          {definitions ++ extracted.definitions, modules ++ extracted.modules}

        {:error, reason} ->
          Mix.shell().error("grasp: skipping #{relative}: #{inspect(reason)}")
          {definitions, modules}
      end
    end)
  end

  defp function_json(record) do
    %{
      "id" => record.id,
      "module" => record.module,
      "name" => Atom.to_string(record.name),
      "arity" => record.arity,
      "arities" => record.arities,
      "kind" => Atom.to_string(record.kind),
      "file" => record.file,
      "span" => %{"start_line" => record.span.start_line, "end_line" => record.span.end_line},
      "source" => record.source,
      "calls" =>
        Enum.map(record.calls, fn call ->
          %{
            "target" => call.target,
            "kind" => Atom.to_string(call.kind),
            "range" => %{
              "start" => Tuple.to_list(call.range.start),
              "end" => Tuple.to_list(call.range.end)
            }
          }
        end),
      "hidden_calls" =>
        Enum.map(
          record.hidden_calls,
          &%{"target" => &1.target, "kind" => Atom.to_string(&1.kind), "line" => &1.line}
        ),
      "change" => "unchanged",
      "base_source" => nil,
      "removed" => false
    }
  end

  defp git_info(root) do
    with {head, 0} <- git(["rev-parse", "HEAD"], root),
         {branch, 0} <- git(["rev-parse", "--abbrev-ref", "HEAD"], root) do
      %{
        "head" => String.trim(head),
        "branch" => String.trim(branch),
        "base_ref" => nil,
        "base_sha" => nil
      }
    else
      _ -> nil
    end
  end

  defp git(args, root) do
    System.cmd("git", args, cd: root, stderr_to_stdout: true)
  rescue
    ErlangError -> {"", 1}
  end
end
