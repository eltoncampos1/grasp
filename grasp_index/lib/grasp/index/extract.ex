defmodule Grasp.Index.Extract do
  @moduledoc """
  Reads one Elixir source file with Sourceror and returns its function definitions and
  the call sites inside them.

  A definition groups every clause of a `{module, name, arity}` — including the extra
  arities a head with default arguments introduces — into one record whose span runs
  from the first attached attribute (`@doc`, `@spec`, `@impl`, `@deprecated`, `@since`)
  or leading comment through the last clause's end. Module names come from the
  `defmodule` nesting, including `__MODULE__.Sub` heads; a `defmodule` whose name is
  not a literal alias is skipped. Call sites are every call node in a clause, keyed by
  the position the compiler reports for that call — the line and column of the function
  name — so `Grasp.Index.Join` can pair them with tracer events. A site's range covers
  the callee only (`Formatter.wrap`, `shout`, `double`), never its arguments, so ranges
  don't nest when rendered. A range can span lines: a receiver written on its own line
  (`Enum\n.map(list, f)`) starts the range one line above the name the compiler reports.

  Each definition also records where its clause heads are: `head_positions` is the
  `{line, column}` of the function name in every clause and `head_ranges` the matching
  ranges over that name. `Grasp.Index.Join` uses the positions to drop the events the
  compiler reports while registering a definition, and the range to place the call a
  `defdelegate` makes, which the compiler reports with no column at all.
  """

  @type range :: %{start: {pos_integer(), pos_integer()}, end: {pos_integer(), pos_integer()}}
  @type position :: {pos_integer(), pos_integer()}
  @type call_site :: %{line: pos_integer(), column: pos_integer(), range: range()}
  @type kind :: :def | :defp | :defmacro | :defmacrop | :defguard | :defguardp | :defdelegate

  @type definition :: %{
          module: String.t(),
          name: atom(),
          arity: non_neg_integer(),
          arities: [non_neg_integer()],
          kind: kind(),
          file: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          source: String.t(),
          call_sites: [call_site()],
          head_positions: [position()],
          head_ranges: [range()]
        }

  @type module_info :: %{name: String.t(), file: String.t(), line: pos_integer()}

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]
  @attached_attributes [:doc, :spec, :impl, :deprecated, :since]
  # Special forms and operators the compiler never reports as calls; leaving them in
  # would produce sites no tracer event can ever land on.
  @not_calls [
    :__block__,
    :__aliases__,
    :.,
    :fn,
    :->,
    :__MODULE__,
    :unquote,
    :unquote_splicing,
    :/,
    :=,
    :when,
    :%{},
    :{},
    :<<>>,
    :^,
    :|,
    :%,
    :"::",
    :\\
  ]

  @doc "Parses `source`, read from the project-relative `file`, into definitions and modules."
  @spec extract(String.t(), String.t()) ::
          {:ok, %{definitions: [definition()], modules: [module_info()]}} | {:error, term()}
  def extract(source, file) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      lines = String.split(source, "\n")
      acc = walk(ast, [], %{definitions: [], modules: [], lines: lines, file: file})
      {:ok, %{definitions: Enum.reverse(acc.definitions), modules: Enum.reverse(acc.modules)}}
    end
  end

  defp walk({:defmodule, meta, [name_ast, body]}, stack, acc) do
    case module_name(name_ast, stack) do
      nil ->
        acc

      name ->
        parts = String.split(name, ".")
        acc = %{acc | modules: [%{name: name, file: acc.file, line: meta[:line]} | acc.modules]}
        body |> do_block_exprs() |> collect_definitions(name, parts, acc)
    end
  end

  defp walk({:__block__, _, exprs}, stack, acc), do: Enum.reduce(exprs, acc, &walk(&1, stack, &2))
  defp walk(_other, _stack, acc), do: acc

  defp module_name({:__aliases__, _, [:"Elixir" | parts]}, _stack), do: join_alias(parts, [])

  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, stack),
    do: join_alias(parts, stack)

  defp module_name({:__aliases__, _, parts}, stack), do: join_alias(parts, stack)
  defp module_name(_dynamic, _stack), do: nil

  defp join_alias(parts, stack) do
    if Enum.all?(parts, &is_atom/1) do
      Enum.join(stack ++ Enum.map(parts, &Atom.to_string/1), ".")
    end
  end

  defp do_block_exprs([{{:__block__, _, [:do]}, {:__block__, _, exprs}} | _]), do: exprs
  defp do_block_exprs([{{:__block__, _, [:do]}, expr} | _]), do: [expr]
  defp do_block_exprs(_), do: []

  # Walks a module body in order, carrying the attributes that will attach to the next
  # definition; anything that is neither an attached attribute nor a definition resets them.
  defp collect_definitions(exprs, module, parts, acc) do
    {acc, _pending} =
      Enum.reduce(exprs, {acc, []}, fn
        {:@, _, [{attr, _, _}]} = node, {acc, pending} when attr in @attached_attributes ->
          {acc, pending ++ [node]}

        {kind, _, [head | _]} = node, {acc, pending} when kind in @def_kinds ->
          {add_clause(acc, module, kind, head, node, pending), []}

        {:defmodule, _, _} = node, {acc, _pending} ->
          {walk(node, parts, acc), []}

        _other, {acc, _pending} ->
          {acc, []}
      end)

    acc
  end

  defp add_clause(acc, module, kind, head, node, pending) do
    case head_signature(head) do
      nil ->
        acc

      {name, arity, arities} ->
        first = List.first(pending) || node

        %{start: [line: start_line, column: _]} =
          Sourceror.get_range(first, include_comments: true)

        %{end: [line: end_line, column: _]} = Sourceror.get_range(node)
        sites = call_sites(node)
        {head_positions, head_ranges} = head_location(head, name)

        clause = %{
          module: module,
          name: name,
          arity: arity,
          arities: arities,
          kind: kind,
          file: acc.file,
          start_line: start_line,
          end_line: end_line,
          source: nil,
          call_sites: sites,
          head_positions: head_positions,
          head_ranges: head_ranges
        }

        %{acc | definitions: merge_clause(acc.definitions, clause, acc.lines)}
    end
  end

  defp merge_clause(definitions, clause, lines) do
    key = {clause.module, clause.name, clause.arity}

    case Enum.split_with(definitions, &({&1.module, &1.name, &1.arity} == key)) do
      {[existing], rest} ->
        merged = %{
          existing
          | start_line: min(existing.start_line, clause.start_line),
            end_line: max(existing.end_line, clause.end_line),
            arities: Enum.uniq(Enum.sort(existing.arities ++ clause.arities)),
            call_sites: existing.call_sites ++ clause.call_sites,
            head_positions: Enum.uniq(existing.head_positions ++ clause.head_positions),
            head_ranges: Enum.uniq(existing.head_ranges ++ clause.head_ranges)
        }

        [with_source(merged, lines) | rest]

      {[], rest} ->
        [with_source(clause, lines) | rest]
    end
  end

  defp with_source(definition, lines) do
    source =
      lines
      |> Enum.slice(definition.start_line - 1, definition.end_line - definition.start_line + 1)
      |> Enum.join("\n")

    %{definition | source: source}
  end

  defp head_signature({:when, _, [head, _guard]}), do: head_signature(head)

  defp head_signature({name, _, args}) when is_atom(name) and (is_list(args) or is_nil(args)) do
    args = args || []
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, [_, _]}, &1))
    {name, arity, Enum.to_list((arity - defaults)..arity//1)}
  end

  defp head_signature(_dynamic), do: nil

  defp head_location({:when, _, [head, _guard]}, name), do: head_location(head, name)

  defp head_location({name, meta, _args}, name) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      width = String.length(Atom.to_string(name))
      {[{line, column}], [%{start: {line, column}, end: {line, column + width}}]}
    else
      _ -> {[], []}
    end
  end

  defp head_location(_head, _name), do: {[], []}

  # The head itself is never a call site: the compiler reports its bookkeeping there, and
  # a site would put those events on the function name. Guards are searched because custom
  # guards (`when is_pos(x)`) are real calls, and so are default arguments, whose
  # expressions the compiler reports at their own position inside the head.
  defp call_sites({_kind, _meta, [head | rest]}) do
    {signature, guard} =
      case head do
        {:when, _, [signature, guard]} -> {signature, [guard]}
        _ -> {head, []}
      end

    searched = defaults(signature) ++ guard ++ rest

    {_, sites} =
      Macro.prewalk(searched, [], fn
        {:&, _, [{:/, _, [target, _arity]}]} = node, sites ->
          {node, add_site(sites, target)}

        {{:., _, _}, _, args} = node, sites when is_list(args) ->
          {node, add_site(sites, node)}

        {name, _, args} = node, sites
        when is_atom(name) and is_list(args) and name not in @not_calls ->
          {node, add_site(sites, node)}

        node, sites ->
          {node, sites}
      end)

    sites |> Enum.reverse() |> Enum.uniq_by(&{&1.line, &1.column})
  end

  defp defaults({_name, _meta, args}) when is_list(args),
    do: for({:\\, _, [_arg, default]} <- args, do: default)

  defp defaults(_head), do: []

  defp add_site(sites, node) do
    case call_range(node) do
      nil -> sites
      {line, column, range} -> [%{line: line, column: column, range: range} | sites]
    end
  end

  # Remote call: the compiler reports the function name's position; the range starts at
  # the receiver when it is a literal alias/atom (`Formatter.wrap`) and at the name
  # otherwise (`foo().bar`), so nothing but the callee gets wrapped.
  defp call_range({{:., _, [receiver, name]}, meta, _args}) when is_atom(name) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      start =
        case receiver do
          {:__aliases__, alias_meta, _} ->
            {alias_meta[:line], alias_meta[:column]}

          {:__block__, atom_meta, [atom]} when is_atom(atom) ->
            {atom_meta[:line], atom_meta[:column]}

          _expression ->
            {line, column}
        end

      {line, column, %{start: start, end: {line, column + String.length(Atom.to_string(name))}}}
    else
      _ -> nil
    end
  end

  defp call_range({name, meta, _args}) when is_atom(name) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      {line, column,
       %{start: {line, column}, end: {line, column + String.length(Atom.to_string(name))}}}
    else
      _ -> nil
    end
  end

  defp call_range(_other), do: nil
end
