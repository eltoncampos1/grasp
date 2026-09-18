defmodule Grasp.Index.Templates do
  @moduledoc """
  Builds a definition for every template a module embeds, in the shape
  `Grasp.Index.Extract` returns for the functions it reads from Elixir source.

  Phoenix compiles every file an `embed_templates` pattern matches into a one-argument
  function of the embedding module, named after the basename with its format and engine
  extensions dropped, and points `@file` at the template, so the compiler reports the calls
  the template makes against the template's own path. A definition per match is what those
  calls land on, and it gives the template's component tags — scanned by
  `Grasp.Index.Heex` — a range a reader can click. The whole file is the definition: it
  spans line 1 to its last line and its source is the file's text.
  """

  alias Grasp.Index.{Extract, Heex}

  @doc """
  Definitions for the templates `embeds` match, under the project root `root`.

  `definitions` are the ones already read from the project's Elixir sources: a module that
  writes the function by hand keeps that definition and the template is skipped, and where
  two templates would claim one name — the same basename under two formats — the first
  path wins. A file that cannot be read is reported and skipped.
  """
  @spec definitions(String.t(), [Extract.embed()], [Extract.definition()]) :: [
          Extract.definition()
        ]
  def definitions(root, embeds, definitions) do
    written = MapSet.new(definitions, &{&1.module, &1.name, &1.arity})

    {templates, _claimed} =
      embeds
      |> Enum.flat_map(&paths(root, &1))
      |> Enum.uniq()
      |> Enum.reduce({[], written}, fn {module, path}, {templates, claimed} ->
        relative = Path.relative_to(path, root)
        name = name(path)

        if MapSet.member?(claimed, {module, name, 1}) do
          {templates, claimed}
        else
          case File.read(path) do
            {:ok, source} ->
              {[definition(module, name, relative, source) | templates],
               MapSet.put(claimed, {module, name, 1})}

            {:error, reason} ->
              Mix.shell().error("grasp: skipping #{relative}: #{inspect(reason)}")
              {templates, claimed}
          end
        end
      end)

    Enum.reverse(templates)
  end

  # The pattern is relative to the directory of the module that embeds it, and Phoenix
  # appends the extension of every engine it compiles, so `"greet_html/*"` matches
  # `greet_html/show.html.heex` and not the fixtures or assets sitting beside it.
  defp paths(root, embed) do
    directory = Path.dirname(Path.join(root, embed.file))

    directory
    |> Path.join(embed.pattern <> ".{heex,eex}")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{embed.module, &1})
  end

  defp name(path),
    do: path |> Path.basename() |> Path.rootname() |> Path.rootname() |> String.to_atom()

  defp definition(module, name, file, source) do
    %{
      module: module,
      name: name,
      arity: 1,
      arities: [1],
      kind: :template,
      file: file,
      start_line: 1,
      end_line: line_count(source),
      source: source,
      # HEEx is the engine whose tags compile to component calls; an EEx template has none.
      call_sites: if(Path.extname(file) == ".heex", do: Heex.tag_sites(source, {1, 0}), else: []),
      head_positions: [],
      head_ranges: []
    }
  end

  # A trailing newline ends the last line rather than opening another, so a template
  # written the way every file should be spans its content and not one line past it.
  defp line_count(source) do
    count = source |> String.split("\n") |> length()

    if String.ends_with?(source, "\n"), do: max(count - 1, 1), else: count
  end
end
