defmodule Grasp.Index do
  @moduledoc """
  In-memory view of an index document written by `mix grasp.index`.

  Records keep the document's string keys so the viewer and the MCP server render the
  same shape they would read from disk. Functions are keyed by id (`"Mod.fun/arity"`);
  a definition with default arguments is also reachable through each extra arity it
  defines. Callers are derived at load time by inverting every function's calls and
  hidden calls. Search ranks an exact id first, then ids containing the query, then ids
  whose characters contain the query as a subsequence, so `"walcre"` still finds
  `MyApp.Wallets.credit/3`.
  """

  defstruct version: 1,
            generated_at: nil,
            project: %{},
            git: nil,
            modules: [],
            entry_points: [],
            functions: %{},
            aliases: %{},
            callers: %{}

  @type function_record :: %{required(String.t()) => term()}
  @type t :: %__MODULE__{
          version: pos_integer(),
          generated_at: String.t() | nil,
          project: map(),
          git: map() | nil,
          modules: [map()],
          entry_points: [map()],
          functions: %{String.t() => function_record()},
          aliases: %{String.t() => String.t()},
          callers: %{String.t() => [String.t()]}
        }

  @doc "Reads and decodes an index document from `path`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, document} <- Jason.decode(binary) do
      {:ok, from_document(document)}
    end
  end

  @doc "Builds the index from a decoded document (string keys)."
  @spec from_document(map()) :: t()
  def from_document(%{"version" => 1, "functions" => records} = document) do
    functions = Map.new(records, &{&1["id"], &1})

    aliases =
      for record <- records, arity <- record["arities"], into: %{} do
        {"#{record["module"]}.#{record["name"]}/#{arity}", record["id"]}
      end

    callers =
      records
      |> Enum.flat_map(fn record ->
        for call <- record["calls"] ++ record["hidden_calls"] do
          {Map.get(aliases, call["target"], call["target"]), record["id"]}
        end
      end)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {target, callers} -> {target, Enum.sort(callers)} end)

    %__MODULE__{
      version: 1,
      generated_at: document["generated_at"],
      project: document["project"] || %{},
      git: document["git"],
      modules: document["modules"] || [],
      entry_points: document["entry_points"] || [],
      functions: functions,
      aliases: aliases,
      callers: callers
    }
  end

  @doc "Fetches a function by id, following default-argument arities to the definition."
  @spec fetch_function(t(), String.t()) :: {:ok, function_record()} | :error
  def fetch_function(%__MODULE__{} = index, id),
    do: Map.fetch(index.functions, resolve(index, id))

  @doc "Ids of the functions that call `id`, sorted."
  @spec callers(t(), String.t()) :: [String.t()]
  def callers(%__MODULE__{} = index, id), do: Map.get(index.callers, resolve(index, id), [])

  @doc "Ids the function calls (visible and hidden), resolved and sorted."
  @spec callees(t(), String.t()) :: [String.t()]
  def callees(%__MODULE__{} = index, id) do
    case fetch_function(index, id) do
      {:ok, record} ->
        (record["calls"] ++ record["hidden_calls"])
        |> Enum.map(&resolve(index, &1["target"]))
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
    end
  end

  @doc "All function records, sorted by id."
  @spec functions(t()) :: [function_record()]
  def functions(%__MODULE__{} = index),
    do: index.functions |> Map.values() |> Enum.sort_by(& &1["id"])

  @doc "Module records as stored in the document."
  @spec modules(t()) :: [map()]
  def modules(%__MODULE__{} = index), do: index.modules

  @doc "Entry-point records as stored in the document."
  @spec entry_points(t()) :: [map()]
  def entry_points(%__MODULE__{} = index), do: index.entry_points

  @doc "Functions whose `change` is anything but `\"unchanged\"`, sorted by id."
  @spec changed_functions(t()) :: [function_record()]
  def changed_functions(%__MODULE__{} = index) do
    index |> functions() |> Enum.reject(&(&1["change"] == "unchanged"))
  end

  @doc """
  Ranks functions against `query`: exact id, then ids containing it, then ids containing
  it as a subsequence. Case-insensitive; shorter ids win ties.
  """
  @spec search(t(), String.t(), pos_integer()) :: [function_record()]
  def search(%__MODULE__{} = index, query, limit \\ 20) do
    query = query |> String.trim() |> String.downcase()

    if query == "" do
      []
    else
      index.functions
      |> Map.values()
      |> Enum.flat_map(fn record ->
        case score(String.downcase(record["id"]), query) do
          nil -> []
          score -> [{score, record}]
        end
      end)
      |> Enum.sort_by(fn {score, record} ->
        {-score, String.length(record["id"]), record["id"]}
      end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp resolve(%__MODULE__{} = index, id), do: Map.get(index.aliases, id, id)

  defp score(id, query) do
    cond do
      id == query -> 3
      String.contains?(id, query) -> 2
      subsequence?(String.graphemes(id), String.graphemes(query)) -> 1
      true -> nil
    end
  end

  defp subsequence?(_haystack, []), do: true
  defp subsequence?([], _needle), do: false
  defp subsequence?([char | rest], [char | needle]), do: subsequence?(rest, needle)
  defp subsequence?([_ | rest], needle), do: subsequence?(rest, needle)
end
