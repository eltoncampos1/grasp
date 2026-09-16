defmodule Grasp.Index.Builder do
  @moduledoc """
  Builds the index for the Mix project in the current directory and writes it as JSON.

  Runs inside the target project's Mix session (`mix grasp.index`), where the compiler,
  the project configuration and the compiled code are all at hand. It registers
  `Grasp.Index.Tracer`, forces a full recompile so every call in the project is traced
  (dependencies are compiled only if stale and filtered out by path), extracts
  definitions from every `.ex` file under `:elixirc_paths`, joins the two and writes the
  document `Grasp.Index.load/1` reads. Git metadata is best-effort: `nil` when the
  project is not in a repository or `git` is not installed, and a file that cannot be
  read or parsed is reported and skipped rather than aborting the run. Entry points and
  module behaviours come from `Grasp.Index.EntryPoints`, which introspects the modules
  the compile just produced.

  With a `:base` git ref, `Grasp.Index.BaseRef` resolves the commit to compare against and
  `Grasp.Index.Changes` marks every record added, modified, unchanged or removed. The ref
  is resolved before the compile, so a ref no commit answers to fails in a second rather
  than after a full rebuild. Removed functions are written as records like any other, so a
  reader can see what a deleted function was, but they are not definitions this project
  holds: entry-point detection and the set of ids a call can resolve to see only the
  functions the compile produced.
  """

  alias Grasp.Index.{BaseRef, Changes, EntryPoints, Extract, Join, Tracer}

  @type summary :: %{
          path: String.t(),
          functions: non_neg_integer(),
          calls: non_neg_integer(),
          hidden_calls: non_neg_integer(),
          changed: non_neg_integer()
        }

  @doc """
  Traces, extracts, joins and writes the index. `:out` defaults to `.grasp/index.json`.

  `:base` compares the project against a git ref: every record is classified by
  `Grasp.Index.Changes` and the functions the ref holds that the project no longer
  defines are written as removed records. An unresolvable ref aborts the run.
  """
  @spec run(out: String.t(), base: String.t()) :: {:ok, summary()}
  def run(opts) do
    out = Keyword.get(opts, :out, ".grasp/index.json")
    config = Mix.Project.config()
    root = File.cwd!()
    paths = Keyword.get(config, :elixirc_paths, ["lib"])

    base = resolve_base(root, paths, Keyword.get(opts, :base))
    events = trace_compile(root, paths)
    {definitions, modules} = extract_all(root, paths)
    functions = Join.join(definitions, events)

    records =
      if base, do: Changes.classify(functions, compared_sources(base), paths), else: functions

    indexed =
      MapSet.new(for f <- functions, a <- f.arities, do: Join.function_id(f.module, f.name, a))

    %{entry_points: entry_points, behaviours: behaviours} =
      EntryPoints.detect(config[:app], indexed)

    document = %{
      "version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "project" => %{"app" => to_string(config[:app]), "root" => root, "elixirc_paths" => paths},
      "git" => git_info(root, base),
      "modules" => Enum.map(modules, &module_json(&1, behaviours)),
      "functions" => Enum.map(records, &function_json/1),
      "entry_points" =>
        Enum.map(
          entry_points,
          &%{"kind" => &1.kind, "label" => &1.label, "target" => &1.target, "meta" => &1.meta}
        )
    }

    write!(out, Jason.encode!(document, pretty: true))

    {:ok,
     %{
       path: out,
       functions: length(records),
       calls: records |> Enum.map(&length(&1.calls)) |> Enum.sum(),
       hidden_calls: records |> Enum.map(&length(&1.hidden_calls)) |> Enum.sum(),
       changed: Enum.count(records, &(Map.get(&1, :change, "unchanged") != "unchanged"))
     }}
  end

  # Every file the diff touched, under the contents the base had for it. A file the base
  # did not have maps to an empty string rather than being left out: without an entry the
  # classifier cannot tell a file this branch added from one it never touched, and the new
  # file's functions would read as untouched instead of added.
  defp compared_sources(base),
    do: Map.new(base.files, &{&1, Map.get(base.base_sources, &1, "")})

  defp resolve_base(_root, _paths, nil), do: nil

  defp resolve_base(root, paths, ref) do
    case BaseRef.resolve(root, ref, paths: paths) do
      {:ok, base} -> base
      {:error, message} -> Mix.raise("grasp.index: #{message}")
    end
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

      case extract_file(file, relative) do
        {:ok, extracted} ->
          {definitions ++ extracted.definitions, modules ++ extracted.modules}

        {:error, reason} ->
          Mix.shell().error("grasp: skipping #{relative}: #{inspect(reason)}")
          {definitions, modules}
      end
    end)
  end

  defp extract_file(file, relative) do
    case File.read(file) do
      {:ok, source} -> Extract.extract(source, relative)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write!(out, json) do
    with :ok <- File.mkdir_p(Path.dirname(out)),
         :ok <- File.write(out, json) do
      :ok
    else
      {:error, reason} ->
        Mix.raise("grasp.index: cannot write #{out}: #{:file.format_error(reason)}")
    end
  end

  defp module_json(module, behaviours) do
    %{
      "name" => module.name,
      "file" => module.file,
      "line" => module.line,
      "behaviours" => Map.get(behaviours, module.name, [])
    }
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
      "change" => Map.get(record, :change, "unchanged"),
      "base_source" => Map.get(record, :base_source),
      "removed" => Map.get(record, :removed, false)
    }
  end

  defp git_info(root, base) do
    with {head, 0} <- git(["rev-parse", "HEAD"], root),
         {branch, 0} <- git(["rev-parse", "--abbrev-ref", "HEAD"], root) do
      %{
        "head" => String.trim(head),
        "branch" => String.trim(branch),
        "base_ref" => base && base.base_ref,
        "base_sha" => base && base.base_sha
      }
    else
      _ -> nil
    end
  end

  # Captured on its own: git writes warnings to stderr and still exits 0, and a warning
  # folded into stdout would be read as the commit the project is sitting on.
  defp git(args, root) do
    System.cmd("git", args, cd: root)
  rescue
    ErlangError -> {"", 1}
  end
end
