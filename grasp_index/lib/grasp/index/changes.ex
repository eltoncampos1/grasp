defmodule Grasp.Index.Changes do
  @moduledoc """
  Classifies function records against the same functions as they stood at a base commit.

  Every record gains three keys: `:change` — `"added"`, `"modified"`, `"unchanged"` or
  `"removed"` — `:base_source`, the definition's text at the base commit for a modified
  or removed function, and `:removed`.

  A function is identified by its id, `"Module.name/arity"`, never by its position in a
  file, and only a definition whose own text differs from the base reads `"modified"`.
  So "unchanged" is a statement about the function, not about its file: a function that
  moved to another file, or that an insertion above it pushed down the page, is unchanged
  because nothing a reader would review about it has changed.

  Only the files git reported as differing from the base are compared: those are the keys
  of `base_sources`, whether or not the base had anything to say about them. A record in a
  file the diff never touched is unchanged by construction, even when no base definition
  carries its id — the base sources at hand simply do not describe that file. A base
  source that is empty (a file this branch added) or that cannot be parsed contributes no
  definitions, so the functions defined in it read as added.

  Definitions the base holds that no current record answers to become removed records:
  the same shape as any other record, carrying the base file, span and source and no
  calls, so a reader can still see what a deleted function used to be. They are appended
  after the records that were passed in, ordered by id.
  """

  alias Grasp.Index.{Extract, Join}

  @type classified_record :: %{
          id: String.t(),
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: Extract.kind(),
          file: String.t(),
          span: %{start_line: pos_integer(), end_line: pos_integer()},
          source: String.t(),
          calls: [Join.call()],
          hidden_calls: [Join.hidden_call()],
          change: String.t(),
          base_source: String.t() | nil,
          removed: boolean()
        }

  @doc """
  Classifies `records` against `base_sources`, mapping every project-relative path that
  differs from the base to the contents it had there — an empty string for a file the base
  did not have.

  `paths` are the project's compile paths: a base source outside them is ignored, so a
  file the index never looked at cannot invent removed functions.
  """
  @spec classify([Join.function_record()], %{String.t() => String.t()}, [String.t()]) :: [
          classified_record()
        ]
  def classify(records, base_sources, paths) do
    prefixes = Enum.map(paths, &(String.trim_trailing(&1, "/") <> "/"))

    base_sources =
      Map.filter(base_sources, fn {file, _} -> String.starts_with?(file, prefixes) end)

    base_definitions =
      Enum.flat_map(base_sources, fn {file, source} ->
        case Extract.extract(source, file) do
          {:ok, %{definitions: definitions}} -> definitions
          {:error, _reason} -> []
        end
      end)

    base_ids =
      Map.new(base_definitions, &{Join.function_id(&1.module, &1.name, &1.arity), &1})

    compared = MapSet.new(Map.keys(base_sources))
    current_ids = MapSet.new(records, & &1.id)

    removed =
      base_ids
      |> Enum.reject(fn {id, _definition} -> MapSet.member?(current_ids, id) end)
      |> Enum.sort_by(fn {id, _definition} -> id end)
      |> Enum.map(fn {_id, definition} -> removed_record(definition) end)

    Enum.map(records, &classify_record(&1, base_ids, compared)) ++ removed
  end

  defp classify_record(record, base_ids, compared) do
    case Map.fetch(base_ids, record.id) do
      {:ok, definition} ->
        if definition.source == record.source,
          do: change(record, "unchanged", nil),
          else: change(record, "modified", definition.source)

      :error ->
        if MapSet.member?(compared, record.file),
          do: change(record, "added", nil),
          else: change(record, "unchanged", nil)
    end
  end

  defp change(record, change, base_source),
    do: Map.merge(record, %{change: change, base_source: base_source, removed: false})

  defp removed_record(definition) do
    %{
      id: Join.function_id(definition.module, definition.name, definition.arity),
      module: definition.module,
      name: definition.name,
      arity: definition.arity,
      arities: definition.arities,
      kind: definition.kind,
      file: definition.file,
      span: %{start_line: definition.start_line, end_line: definition.end_line},
      source: definition.source,
      calls: [],
      hidden_calls: [],
      change: "removed",
      base_source: definition.source,
      removed: true
    }
  end
end
