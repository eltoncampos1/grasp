defmodule Grasp.Links do
  @moduledoc """
  How one function names another in its own source.

  A card is linked to another card by a call, and the call has two spellings: the
  canonical id of the function it reaches (`Greeter.greet/2`) and the raw target the
  caller wrote (`Greeter.greet/1`, when the call goes through a default-argument arity).
  The graph stores the raw one on the edge, because that is what identifies the call site
  inside the rendered caller; the canonical one only decides which function the call
  reaches. This module is where the two are matched up, over a `Grasp.Index` alone, so the
  web and MCP layers share one answer.
  """

  alias Grasp.Index
  alias Grasp.Paths

  @doc """
  The raw target `caller_function_id` writes for its call to `callee_function_id`, or nil
  when it makes no such call.

  Hidden calls count: a call inside a macro body is still the call the caller makes, and
  the card renders it in its "Also calls" footer. Either id may be written against a
  default-argument arity; both are resolved before they are compared.
  """
  @spec call_target(Index.t(), String.t(), String.t()) :: String.t() | nil
  def call_target(%Index{} = index, caller_function_id, callee_function_id) do
    callee = Paths.canonical(index, callee_function_id)

    with {:ok, caller} <- Index.fetch_function(index, caller_function_id),
         %{"target" => target} <-
           Enum.find(calls(caller), &(Paths.canonical(index, &1["target"]) == callee)) do
      target
    else
      _no_such_call -> nil
    end
  end

  defp calls(record),
    do: Enum.filter(List.wrap(record["calls"]) ++ List.wrap(record["hidden_calls"]), &is_map/1)
end
