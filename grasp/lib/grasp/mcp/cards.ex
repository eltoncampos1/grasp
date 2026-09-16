defmodule Grasp.MCP.Cards do
  @moduledoc """
  Turns the cards an agent describes into a forest spec, or says why it cannot.

  Pure over a `Grasp.Index`: index in, `t:Grasp.Session.Forest.spec/0` list out, so the MCP
  tools stay adapters and every rule an agent can break is stated once here.

  Two things need resolving before the forest can hold a card. A function reached through
  a default-argument arity (`Greeter.greet/1`) is stored under the arity it is defined at
  (`greet/2`), so the card shows the definition. But the parent card marks the call the
  child was opened from by matching the raw target the source wrote, so `opened_by` keeps
  the caller's spelling — the canonical id only decides which call it is. A highlight
  resolves the same way: `%{"call" => target}` is stored as the raw target of the call it
  matched, because that is what the rendered card carries in `data-target`.
  """

  alias Grasp.Index
  alias Grasp.Session.Forest

  @typedoc """
  A card as the tool schema hands it over: atom keys, and the optional ones absent rather
  than nil when the client left them out.
  """
  @type input :: %{
          required(:key) => String.t(),
          required(:function_id) => String.t(),
          optional(:parent_key) => String.t() | nil,
          optional(:highlight) => highlight_input()
        }
  @typedoc "A highlight as the tool schema hands it over; an empty one marks nothing."
  @type highlight_input ::
          nil | %{optional(:call) => String.t() | nil, optional(:lines) => [integer()] | nil}

  @doc """
  Validates and links `cards`, in order, into the spec `Grasp.Session.set_cards/2` takes.

  Every `function_id` must be in the index and every `parent_key` must name an earlier
  card. Unknown functions are collected into one message so an agent fixes them in a
  single round trip rather than one per call.
  """
  @spec prepare(Index.t(), [input()]) :: {:ok, [Forest.spec()]} | {:error, String.t()}
  def prepare(%Index{} = index, cards) when is_list(cards) do
    case Enum.filter(cards, &(Index.fetch_function(index, &1.function_id) == :error)) do
      [] -> link(index, cards)
      unknown -> {:error, "unknown functions: " <> Enum.map_join(unknown, ", ", & &1.function_id)}
    end
  end

  @doc """
  Checks `highlight` against the function it marks.

  A call must be one the function makes, visible or hidden, and is stored as that call's
  raw target. A line range must lie inside the function's span. Nothing, or an empty
  highlight, marks nothing.
  """
  @spec validate_highlight(Index.t(), String.t(), highlight_input()) ::
          {:ok, Forest.highlight()} | {:error, String.t()}
  def validate_highlight(%Index{} = index, function_id, highlight) do
    case Index.fetch_function(index, function_id) do
      :error -> {:error, "unknown function: #{function_id}"}
      {:ok, record} -> highlight(index, record, get(highlight, :call), get(highlight, :lines))
    end
  end

  @doc """
  The raw call target on `parent_id` that opens `child_id`, or `child_id` itself.

  A call written against a default-argument arity resolves to the definition the child
  card shows, and it is the raw spelling that marks the call as open in the parent.
  """
  @spec opened_by(Index.t(), String.t(), String.t()) :: String.t()
  def opened_by(%Index{} = index, parent_id, child_id) do
    with {:ok, parent} <- Index.fetch_function(index, parent_id),
         %{"target" => target} <-
           Enum.find(calls(parent), &(canonical(index, &1["target"]) == child_id)) do
      target
    else
      _no_such_call -> child_id
    end
  end

  # `opened` maps each key seen so far to the function its card shows, which is both the
  # check that a `parent_key` names an earlier card and the record `opened_by` is read from.
  defp link(index, cards) do
    cards
    |> Enum.reduce_while({[], %{}}, fn card, {specs, opened} ->
      case spec(index, opened, card) do
        {:ok, spec} -> {:cont, {[spec | specs], Map.put(opened, spec.key, spec.function_id)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _message} = error -> error
      {specs, _opened} -> {:ok, Enum.reverse(specs)}
    end
  end

  defp spec(index, opened, card) do
    parent_key = get(card, :parent_key)
    {:ok, record} = Index.fetch_function(index, card.function_id)

    with {:ok, parent_id} <- parent(opened, parent_key),
         {:ok, highlight} <- validate_highlight(index, record["id"], get(card, :highlight)) do
      {:ok,
       %{
         key: card.key,
         function_id: record["id"],
         parent_key: parent_key,
         opened_by: parent_id && opened_by(index, parent_id, record["id"]),
         highlight: highlight
       }}
    end
  end

  defp parent(_opened, nil), do: {:ok, nil}

  defp parent(opened, key) do
    case Map.fetch(opened, key) do
      {:ok, function_id} -> {:ok, function_id}
      :error -> {:error, "unknown parent key: #{key}"}
    end
  end

  defp highlight(_index, _record, nil, nil), do: {:ok, nil}

  defp highlight(_index, record, call, lines) when not is_nil(call) and not is_nil(lines),
    do: {:error, "#{record["id"]}: a highlight names either a call or lines, not both"}

  defp highlight(index, record, call, nil) do
    target = canonical(index, call)

    case Enum.find(calls(record), &(canonical(index, &1["target"]) == target)) do
      %{"target" => raw} -> {:ok, %{"call" => raw}}
      nil -> {:error, "#{record["id"]} does not call #{call}"}
    end
  end

  defp highlight(_index, record, nil, [first, last])
       when is_integer(first) and is_integer(last) do
    %{"start_line" => start_line, "end_line" => end_line} = record["span"]

    if start_line <= first and first <= last and last <= end_line do
      {:ok, %{"lines" => [first, last]}}
    else
      {:error,
       "lines #{first}-#{last} fall outside #{record["id"]}, which spans #{start_line}-#{end_line}"}
    end
  end

  defp highlight(_index, record, nil, _lines),
    do: {:error, "#{record["id"]}: a line highlight takes two line numbers, first and last"}

  defp calls(record),
    do: Enum.filter(List.wrap(record["calls"]) ++ List.wrap(record["hidden_calls"]), &is_map/1)

  defp canonical(index, id) do
    case Index.fetch_function(index, id) do
      {:ok, record} -> record["id"]
      :error -> id
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key), do: Map.get(map, key)
end
