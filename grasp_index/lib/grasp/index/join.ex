defmodule Grasp.Index.Join do
  @moduledoc """
  Pairs compiler tracer events with the definitions Sourceror extracted, producing the
  function records the index stores.

  An event is attributed to the definition whose module, name and arity match the caller
  the compiler reported; a definition registers every arity its default arguments
  introduce, so calls made through any of them land on it. The event's line and column
  then locate the call node inside that definition, giving a call with a clickable range.

  Four rules decide what survives:

    * **Head positions.** The compiler reports its own bookkeeping at every clause head —
      `Module.compile_definition_attributes/6` and any `@on_definition` hook a library
      installs — at the head's line and the function name's column. Every event at a
      position the definition lists as a head is dropped.
    * **Compiler internals.** Targets in `Kernel`, `Kernel.SpecialForms` and
      `Kernel.Utils`, and in the compiler's own Erlang modules (`:elixir_quote`,
      `:elixir_def`, ...), describe how the code was expanded rather than what it calls.
      `unquote(x)` inside a macro body, reported as `:elixir_quote.unquote/1`, is the
      common case.
    * **`defdelegate`.** The delegated call is reported with no column, so it can only be
      placed by kind: for a `defdelegate`, a column-less event becomes a visible call
      ranged over the delegate's own name. Column-less events elsewhere (boolean
      operators expanded from `if`, bookkeeping on a delegate head) are dropped.
    * **Hidden calls.** An event with a column but no matching node came from
      macro-generated code — a function component in a `~H` template, code injected by
      `use` — and is kept as a hidden call so the graph stays complete even though
      nothing in the source can be clicked.
  """

  alias Grasp.Index.{Extract, Tracer}

  @ignored_targets [Kernel, Kernel.SpecialForms, Kernel.Utils]
  # Reported at every definition. Most kinds carry the head's position, where the
  # positional rule catches it; a `defdelegate` reports it with no column, and there only
  # the target tells it apart from the delegated call.
  @definition_bookkeeping {Module, :compile_definition_attributes, 6}

  @type call :: %{target: String.t(), kind: Tracer.kind(), range: Extract.range()}
  @type hidden_call :: %{target: String.t(), kind: Tracer.kind(), line: pos_integer()}

  @type function_record :: %{
          id: String.t(),
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: Extract.kind(),
          file: String.t(),
          span: %{start_line: pos_integer(), end_line: pos_integer()},
          source: String.t(),
          calls: [call()],
          hidden_calls: [hidden_call()]
        }

  @doc "Builds the `\"Module.name/arity\"` id; `module` may be an atom or its `inspect/1` form."
  @spec function_id(module() | String.t(), atom(), non_neg_integer()) :: String.t()
  def function_id(module, name, arity) when is_atom(module),
    do: function_id(inspect(module), name, arity)

  def function_id(module, name, arity) when is_binary(module), do: "#{module}.#{name}/#{arity}"

  @doc "Turns definitions and tracer events into function records with resolved calls."
  @spec join([Extract.definition()], [Tracer.event()]) :: [function_record()]
  def join(definitions, events) do
    canonical =
      for definition <- definitions, arity <- definition.arities, into: %{} do
        {{definition.module, definition.name, arity},
         {definition.module, definition.name, definition.arity}}
      end

    events_by_definition =
      events
      |> Enum.filter(&keep?/1)
      |> Enum.group_by(fn event ->
        {name, arity} = event.function
        Map.get(canonical, {inspect(event.module), name, arity})
      end)

    Enum.map(definitions, fn definition ->
      key = {definition.module, definition.name, definition.arity}
      build(definition, Map.get(events_by_definition, key, []))
    end)
  end

  defp keep?(%{target: {module, _, _}}) when module in @ignored_targets, do: false
  defp keep?(%{target: {module, _, _}}), do: not compiler_internal?(module)

  defp compiler_internal?(module),
    do: module |> Atom.to_string() |> String.starts_with?("elixir_")

  defp build(definition, events) do
    sites = Map.new(definition.call_sites, &{{&1.line, &1.column}, &1.range})
    heads = MapSet.new(definition.head_positions)
    delegate_range = if definition.kind == :defdelegate, do: List.first(definition.head_ranges)

    {calls, hidden} =
      Enum.reduce(events, {[], []}, fn event, {calls, hidden} ->
        {module, name, arity} = event.target
        target = function_id(module, name, arity)
        call = fn range -> %{target: target, kind: event.kind, range: range} end

        cond do
          MapSet.member?(heads, {event.line, event.column}) ->
            {calls, hidden}

          event.column == nil ->
            if delegate_range && event.target != @definition_bookkeeping,
              do: {[call.(delegate_range) | calls], hidden},
              else: {calls, hidden}

          true ->
            case Map.fetch(sites, {event.line, event.column}) do
              {:ok, range} -> {[call.(range) | calls], hidden}
              :error -> {calls, [%{target: target, kind: event.kind, line: event.line} | hidden]}
            end
        end
      end)

    %{
      id: function_id(definition.module, definition.name, definition.arity),
      module: definition.module,
      name: definition.name,
      arity: definition.arity,
      arities: definition.arities,
      kind: definition.kind,
      file: definition.file,
      span: %{start_line: definition.start_line, end_line: definition.end_line},
      source: definition.source,
      calls: calls |> Enum.uniq() |> Enum.sort_by(&{&1.range.start, &1.target, &1.kind}),
      hidden_calls: hidden |> Enum.uniq() |> Enum.sort_by(&{&1.line, &1.target, &1.kind})
    }
  end
end
