defmodule Grasp.Index.Join do
  @moduledoc """
  Pairs compiler tracer events with the definitions Sourceror extracted, producing the
  function records the index stores.

  An event is attributed to the definition whose module, name and arity match the caller
  the compiler reported; a definition registers every arity its default arguments
  introduce, so calls made through any of them land on it. The event's line and column
  then locate the call node inside that definition, giving a call with a clickable range.

  Six rules decide what survives:

    * **Head positions.** The compiler reports its own bookkeeping at every clause head —
      `Module.compile_definition_attributes/6` and any `@on_definition` hook a library
      installs — at the head's line and the function name's column. Every event at a
      position the definition lists as a head is dropped.
    * **Compiler internals.** Targets in `Kernel`, `Kernel.SpecialForms` and
      `Kernel.Utils`, and in the compiler's own Erlang modules (`:elixir_quote`,
      `:elixir_def`, ...), describe how the code was expanded rather than what it calls.
      `unquote(x)` inside a macro body, reported as `:elixir_quote.unquote/1`, is the
      common case.
    * **Reflection.** A `__name__`-shaped target — `__schema__/1`, `__struct__/1`,
      `Phoenix.VerifiedRoutes.__encode_segment__/1` — is machinery a macro expanded into,
      never a call anyone wrote, so it is dropped wherever it was reported. Position is no
      defence: a `~p` sigil reports its segment encoder at the interpolation's own line and
      column, which matches a real call node, and the rules below would otherwise hand the
      reader a clickable call that says nothing about what the function does.
    * **`defdelegate`.** The delegated call is reported with no column, so it can only be
      placed by kind: for a `defdelegate`, a column-less event becomes a visible call
      ranged over the delegate's own name.
    * **Column-less events.** Macro- and template-generated code is reported without a
      column — a context call inside a `~H` body is the common case. Outside a
      `defdelegate` (which turns its one column-less delegated call into a visible call),
      such an event becomes a hidden call only when its line falls inside the definition's
      span *and* its target is a definition the index holds. A macro that expands into a
      dependency — a template engine, a query builder, `Logger` — reports the macro's own
      implementation, not what the function set out to do, and on a real project those
      outnumber the project calls worth seeing by more than ten to one; OTP's `:erlang`
      operators that `and` and `>` expand to are not definitions the index holds, so they
      fall out the same way.
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
    {canonical, indexed} = reachable(definitions)

    events_by_definition =
      events
      |> Enum.filter(&keep?/1)
      |> Enum.group_by(fn event ->
        {name, arity} = event.function
        Map.get(canonical, {inspect(event.module), name, arity})
      end)

    Enum.map(definitions, fn definition ->
      key = {definition.module, definition.name, definition.arity}
      build(definition, Map.get(events_by_definition, key, []), indexed)
    end)
  end

  # Every arity a definition answers to, paired with the definition it resolves to and
  # collected into the set of ids the index holds, in one pass over the definitions.
  defp reachable(definitions) do
    Enum.reduce(definitions, {%{}, MapSet.new()}, fn definition, acc ->
      key = {definition.module, definition.name, definition.arity}

      Enum.reduce(definition.arities, acc, fn arity, {canonical, indexed} ->
        {Map.put(canonical, {definition.module, definition.name, arity}, key),
         MapSet.put(indexed, function_id(definition.module, definition.name, arity))}
      end)
    end)
  end

  defp keep?(%{target: {module, _, _}}) when module in @ignored_targets, do: false

  defp keep?(%{target: {module, name, _}}),
    do: not compiler_internal?(module) and not reflection?(name)

  defp compiler_internal?(module),
    do: module |> Atom.to_string() |> String.starts_with?("elixir_")

  defp reflection?(name) do
    name = Atom.to_string(name)
    String.starts_with?(name, "__") and String.ends_with?(name, "__")
  end

  defp build(definition, events, indexed) do
    sites = Map.new(definition.call_sites, &{{&1.line, &1.column}, &1.range})
    heads = MapSet.new(definition.head_positions)
    delegate_range = if definition.kind == :defdelegate, do: List.first(definition.head_ranges)
    span = definition.start_line..definition.end_line

    {calls, hidden} =
      Enum.reduce(events, {[], []}, fn event, {calls, hidden} ->
        {module, name, arity} = event.target
        target = function_id(module, name, arity)
        call = fn range -> %{target: target, kind: event.kind, range: range} end
        hidden_call = %{target: target, kind: event.kind, line: event.line}

        cond do
          MapSet.member?(heads, {event.line, event.column}) ->
            {calls, hidden}

          event.column == nil and event.target == @definition_bookkeeping ->
            {calls, hidden}

          event.column == nil ->
            cond do
              delegate_range -> {[call.(delegate_range) | calls], hidden}
              not MapSet.member?(indexed, target) -> {calls, hidden}
              event.line in span -> {calls, [hidden_call | hidden]}
              true -> {calls, hidden}
            end

          true ->
            case Map.fetch(sites, {event.line, event.column}) do
              {:ok, range} -> {[call.(range) | calls], hidden}
              :error -> {calls, [hidden_call | hidden]}
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
