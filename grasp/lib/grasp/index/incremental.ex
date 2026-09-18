defmodule Grasp.Index.Incremental do
  @moduledoc """
  Rewrites the parts of an index document that a handful of changed files describe,
  leaving every other record exactly as it was.

  `Grasp.Reindexer` calls this after the host's code reloader has recompiled what a save
  touched. The stages are the ones `Grasp.Index.Builder.run/1` walks for the whole
  project — extract, join, entry points, classify — run over the changed files only, so a
  record this produces has the same shape as a record the full build writes.

  Which files count as changed is widened before anything is read. A template is compiled
  into the module that embeds it, so a saved `.heex` and the `.ex` holding its
  `embed_templates` have to move together: a changed template pulls in the file of the
  module that embeds it, and a changed module pulls in the templates it already owns. The
  `.ex` files in that set are re-extracted, the templates are rebuilt from the embeds
  those files declare, and the tracer events of any other file are ignored — they describe
  functions this update is not rebuilding.

  Calls reaching out of the changed files still resolve, because the ids of the records
  being kept are handed to `Grasp.Index.Join.join/3`: without them a hidden call into an
  untouched module would read as a call into nothing and disappear from the graph.

  Classification is per file, against the base commit the document was built with: the
  base contents of the changed files come from `git show`, and a file the base does not
  hold compares against an empty string, which is how `Grasp.Index.Changes` recognises a
  file the branch added. With no base commit, records are left `"unchanged"`.

  Entry points and module behaviours are recomputed from the modules the VM has loaded. A
  VM that cannot see the application at all keeps what the document already held, so
  reading a document built elsewhere does not empty its sidebar.

  ## What it cannot see

  The update is scoped to files, and that is also its limit.

    * A function that moved from one file to another is removed from the file it left only
      when that file is in the changed set too. A move that recompiles only one of the two
      leaves the record in the other, and the id is briefly held twice.
    * A file that no longer exists drops its definitions, but only if something still
      names it — the compiler reports no events for a deleted file, so a deletion is seen
      through the modules that used to call into it.
    * Entry points are recomputed from the modules loaded in the running VM, so a route
      added to a router the reloader has not compiled yet is not there.
    * Which files are compiled at all is fixed at the document's `elixirc_paths`.

  `mix grasp.index` is the answer to each of those: it is the full build, and it stays.
  """

  alias Grasp.Index.{Builder, Changes, EntryPoints, Join, Templates}

  @type base_context :: %{root: String.t(), base_sha: String.t(), paths: [String.t()]}

  @doc """
  Merges the changed files into `document` and returns the new document.

  `changed_files` are project-relative paths under `root`, `events` the tracer events the
  compile produced (events naming other files are dropped), and `base_ctx` either `nil` or
  a map carrying the repository `:root`, the `:base_sha` to compare against and the
  project's compile `:paths`.
  """
  @spec update(
          map(),
          String.t(),
          [String.t()],
          [Grasp.Index.Tracer.event()],
          base_context() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def update(document, root, changed_files, events, base_ctx) do
    project = document["project"] || %{}
    paths = project["elixirc_paths"] || ["lib"]
    changed = widen(document, changed_files)

    sources = changed |> Enum.filter(&source?(root, &1)) |> Enum.sort()
    extracted = Builder.extract(root, sources)

    templates = Templates.definitions(root, extracted.embeds, extracted.definitions)

    definitions = extracted.definitions ++ templates
    rebuilt = MapSet.union(changed, MapSet.new(templates, & &1.file))

    kept = Enum.reject(document["functions"] || [], &MapSet.member?(rebuilt, &1["file"]))

    records =
      definitions
      |> Join.join(events_for(events, definitions), ids(kept))
      |> classify(rebuilt, base_ctx, paths)

    functions = kept ++ Enum.map(records, &Builder.function_json/1)
    kept_modules = Enum.reject(document["modules"] || [], &MapSet.member?(rebuilt, &1["file"]))
    {entry_points, behaviours} = detect(document, project["app"], functions)

    {:ok,
     document
     |> Map.put("generated_at", timestamp())
     |> Map.put("functions", functions)
     |> Map.put(
       "modules",
       kept_modules ++ Enum.map(extracted.modules, &Builder.module_json(&1, behaviours))
     )
     |> Map.put("entry_points", entry_points)}
  rescue
    error -> {:error, error}
  end

  # A VM that cannot see the application — one where the app's name is not an atom, or its
  # modules are not in the code path — has nothing to say about entry points, which is not
  # the same as a project whose routers lost their routes. The document keeps what the full
  # build found there.
  defp detect(document, app, functions) do
    app = app_name(app)

    if EntryPoints.available?(app) do
      detected = EntryPoints.detect(app, ids(functions))
      {Enum.map(detected.entry_points, &entry_point_json/1), detected.behaviours}
    else
      {document["entry_points"] || [],
       Map.new(document["modules"] || [], &{&1["name"], &1["behaviours"] || []})}
    end
  end

  defp entry_point_json(entry),
    do: %{
      "kind" => entry.kind,
      "label" => entry.label,
      "target" => entry.target,
      "meta" => entry.meta
    }

  # Every id the given document records answer to. A removed record describes a function
  # the base commit had and this project no longer defines, so nothing may resolve to it.
  defp ids(records) do
    for record <- records,
        record["removed"] != true,
        arity <- record["arities"],
        into: MapSet.new(),
        do: Join.function_id(record["module"], record["name"], arity)
  end

  # A template is compiled into the module that embeds it and reported under its own path,
  # so neither side can be rebuilt without the other: the module's embeds are where the
  # template definition comes from, and the template's text is what the module's record
  # points at.
  defp widen(document, changed_files) do
    changed = MapSet.new(changed_files)
    module_files = Map.new(document["modules"] || [], &{&1["name"], &1["file"]})

    Enum.reduce(document["functions"] || [], changed, fn record, acc ->
      embedding = Map.get(module_files, record["module"])

      cond do
        record["kind"] != "template" or is_nil(embedding) -> acc
        MapSet.member?(changed, record["file"]) -> MapSet.put(acc, embedding)
        MapSet.member?(changed, embedding) -> MapSet.put(acc, record["file"])
        true -> acc
      end
    end)
  end

  defp source?(root, file),
    do: Path.extname(file) == ".ex" and File.regular?(Path.join(root, file))

  defp events_for(events, definitions) do
    files = MapSet.new(definitions, & &1.file)
    Enum.filter(events, &MapSet.member?(files, &1.file))
  end

  defp classify(records, _rebuilt, nil, _paths), do: records

  defp classify(records, rebuilt, base_ctx, paths) do
    compared = Map.new(rebuilt, &{&1, base_source(base_ctx, &1)})
    Changes.classify(records, compared, paths)
  end

  # A file the base commit does not hold is an empty string rather than a missing key:
  # `Grasp.Index.Changes` reads the absence of a key as "this file was never touched" and
  # would call every function in a file the branch added unchanged.
  defp base_source(base_ctx, file) do
    object = "#{base_ctx.base_sha}:./#{file}"

    # Existence is asked first, with git's own complaint swallowed, so a file the branch
    # added does not print a fatal error into the host's console on every save; `show`
    # then runs with stderr left alone, so nothing git says can land inside the source.
    with {_output, 0} <-
           System.cmd("git", ["cat-file", "-e", object],
             cd: base_ctx.root,
             stderr_to_stdout: true
           ),
         {source, 0} <- System.cmd("git", ["show", object], cd: base_ctx.root) do
      source
    else
      _missing -> ""
    end
  rescue
    ErlangError -> ""
  end

  defp app_name(nil), do: nil

  defp app_name(app) when is_binary(app) do
    String.to_existing_atom(app)
  rescue
    ArgumentError -> nil
  end

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
