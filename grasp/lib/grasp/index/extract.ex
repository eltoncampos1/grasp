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

  A `~H` sigil in a definition body contributes call sites too: `Grasp.Index.Heex` scans the
  template for component tags and yields the body of every interpolation, this module parses
  those bodies, and the sites the two produce join the ones the Elixir AST produced. The
  sigil itself is not one of them — a call whose name begins with `sigil_` never becomes a
  site, since the macro behind a sigil builds a literal rather than calling anything. A heredoc
  `~H\"""` starts on the line after the sigil, with the `indentation` Sourceror records on
  the sigil's string stripped from every line, which is where the file has it too. A
  single-line `~H"..."` is the one place a site's key and its range part ways: Phoenix
  compiles it as though it began on the next line at column 1, so the site is keyed there —
  where the tracer reports its calls — while the `range` stays on the sigil's own line,
  three columns past the `~`, where the reader sees the code. A site made from a `render`
  call whose second argument is a literal atom or string also carries that literal as
  `template`, with any `.html` suffix removed, which is the name of the template the call
  renders.

  An interpolation is Elixir, so its body is parsed rather than skipped: `Sourceror` reads
  it at the file position `Grasp.Index.Heex` reports, and the same walk that reads a clause
  body collects its call sites, so a call written in a tag body, an attribute value or an
  EEx expression tag is a site a reader can click. A body that is only part of an
  expression — the `if ... do` half of a block — is retried with an `end` appended, and a
  body no parse can make sense of (`else`, `end`, a comment) contributes nothing. Every
  site also records its `callee`, the call as it is written, because the compiler reports
  the calls of a `{...}` interpolation with a line and no column at all: `Grasp.Index.Join`
  places those by name, arity and the module the source spells out.

  Each definition also records where its clause heads are: `head_positions` is the
  `{line, column}` of the function name in every clause and `head_ranges` the matching
  ranges over that name. `Grasp.Index.Join` uses the positions to drop the events the
  compiler reports while registering a definition, and the range to place the call a
  `defdelegate` makes, which the compiler reports with no column at all.
  """

  alias Grasp.Index.Heex

  @type range :: %{start: {pos_integer(), pos_integer()}, end: {pos_integer(), pos_integer()}}
  @type position :: {pos_integer(), pos_integer()}
  @type callee :: %{module: String.t() | nil, name: atom(), arity: non_neg_integer()}
  # `callee` is the call as written: `module` is the literal receiver — an alias joined
  # with "." (`"Greeter"`, `"SampleApp.Greeter"`) or an Erlang module's own text — and is
  # `nil` for a local or imported call and for a receiver that is an expression
  # (`mod.f(x)`); `name` is the function and `arity` the arity as written, which for a
  # capture (`&Mod.f/2`) is the one after the slash and for a piped call counts the piped
  # value as the first argument. A component tag has no callee: the compiler always reports
  # it with a column, so it is never placed by name.
  @type call_site :: %{
          line: pos_integer(),
          column: pos_integer(),
          range: range(),
          template: String.t() | nil,
          callee: callee() | nil
        }
  # `:template` is not a kind this module reads: `Grasp.Index.Templates` builds a definition
  # of that kind, in this same shape, for every file an `embed_templates` pattern matches.
  @type kind ::
          :def
          | :defp
          | :defmacro
          | :defmacrop
          | :defguard
          | :defguardp
          | :defdelegate
          | :template

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

  @type embed :: %{
          module: String.t(),
          pattern: String.t(),
          suffix: String.t() | nil,
          root: String.t() | nil,
          file: String.t(),
          line: pos_integer()
        }

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

  @doc """
  Parses `source`, read from the project-relative `file`, into definitions, modules and
  the template patterns its modules embed.

  An embed carries the pattern and the `:suffix` and `:root` options that decide what the
  embedded functions are called and where they are looked for; an option that is not a
  literal string reads as absent.
  """
  @spec extract(String.t(), String.t()) ::
          {:ok, %{definitions: [definition()], modules: [module_info()], embeds: [embed()]}}
          | {:error, term()}
  def extract(source, file) do
    with {:ok, ast} <- Sourceror.parse_string(source) do
      lines = String.split(source, "\n")

      acc =
        walk(ast, [], %{definitions: [], modules: [], embeds: [], lines: lines, file: file})

      {:ok,
       %{
         definitions: Enum.reverse(acc.definitions),
         modules: Enum.reverse(acc.modules),
         embeds: Enum.reverse(acc.embeds)
       }}
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

        {:embed_templates, meta, [pattern | opts]}, {acc, _pending} ->
          {add_embed(acc, module, pattern, opts, meta), []}

        _other, {acc, _pending} ->
          {acc, []}
      end)

    acc
  end

  defp add_embed(acc, module, {:__block__, _meta, [pattern]}, opts, meta)
       when is_binary(pattern) do
    embed = %{
      module: module,
      pattern: pattern,
      suffix: embed_option(opts, :suffix),
      root: embed_option(opts, :root),
      file: acc.file,
      line: meta[:line]
    }

    %{acc | embeds: [embed | acc.embeds]}
  end

  defp add_embed(acc, _module, _dynamic_pattern, _opts, _meta), do: acc

  # Only a literal string in a literal keyword list is read. An option computed elsewhere
  # (`suffix: @suffix`) is a value no parser can know, and guessing it would name a function
  # the compiler never defined, so it reads as absent.
  defp embed_option([opts], key) when is_list(opts) do
    Enum.find_value(opts, fn
      {{:__block__, _, [^key]}, {:__block__, _, [value]}} when is_binary(value) -> value
      _pair -> nil
    end)
  end

  defp embed_option(_opts, _key), do: nil

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

    collect_sites(defaults(signature) ++ guard ++ rest)
  end

  @doc """
  Call sites for the Elixir written inside one interpolation body.

  `text` is parsed at `line` and `column`, the file position of its first character, so
  every site it yields carries the file's own coordinates. A body that does not parse is
  retried with an `end` appended, which is what an expression tag that opens a block
  (`<%= if allowed?(@user) do %>`) needs; a body that still does not parse yields nothing.
  """
  @spec expression_sites(String.t(), pos_integer(), pos_integer()) :: [call_site()]
  def expression_sites(text, line, column)
      when is_binary(text) and is_integer(line) and is_integer(column) do
    options = [line: line, column: column]

    case Sourceror.parse_string(text, options) do
      {:ok, ast} ->
        collect_sites(ast)

      {:error, _reason} ->
        case Sourceror.parse_string(text <> "\nend", options) do
          {:ok, ast} -> collect_sites(ast)
          {:error, _reason} -> []
        end
    end
  end

  @doc """
  Every call site a template's text holds: its component tags and its interpolations.

  The position arguments are `Grasp.Index.Heex.tag_sites/3`'s. Sites are returned in
  document order, one per position, which is the order and the shape `Grasp.Index.Join`
  reads them in.
  """
  @spec template_sites(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [
          call_site()
        ]
  def template_sites(text, first_line_and_indent, first_line_column \\ nil) do
    interpolated =
      text
      |> Heex.interpolations(first_line_and_indent, first_line_column)
      |> Enum.flat_map(&expression_sites(&1.text, &1.line, &1.column))

    (Heex.tag_sites(text, first_line_and_indent, first_line_column) ++ interpolated)
    |> Enum.sort_by(&{&1.line, &1.column})
    |> Enum.uniq_by(&{&1.line, &1.column})
  end

  # One walk reads a clause body and an interpolation body alike, so a call written in a
  # template is the same kind of site as a call written in Elixir.
  defp collect_sites(ast) do
    {_, sites} =
      Macro.prewalk(ast, [], fn
        {:&, _, [{:/, _, [target, arity]}]} = node, sites ->
          {node, add_site(sites, target, written_arity(arity))}

        {:sigil_H, _meta, [{:<<>>, _str_meta, [content]}, _modifiers]} = node, sites
        when is_binary(content) ->
          {node, Enum.reverse(sigil_sites(node)) ++ sites}

        {:|>, _meta, [_left, right]} = node, sites ->
          {node, sites |> add_site(node) |> piped_site(right)}

        {{:., _, _}, _, args} = node, sites when is_list(args) ->
          {node, add_site(sites, node)}

        {name, _, args} = node, sites
        when is_atom(name) and is_list(args) and name not in @not_calls ->
          {node, if(sigil?(name), do: sites, else: add_site(sites, node))}

        node, sites ->
          {node, sites}
      end)

    sites |> Enum.reverse() |> Enum.uniq_by(&{&1.line, &1.column})
  end

  defp written_arity({:__block__, _meta, [arity]}) when is_integer(arity), do: arity
  defp written_arity(_other), do: nil

  # A sigil is written as a call to `sigil_x/2` and the compiler reports it as one, but the
  # macro behind it describes how the literal is built rather than what the code calls.
  defp sigil?(name), do: name |> Atom.to_string() |> String.starts_with?("sigil_")

  # The compiler reports a piped call with the piped value as its first argument, so the
  # site records one more than the arguments written between the parentheses. The prewalk
  # reaches a pipe before its right-hand side, and `collect_sites/1` keeps the first site
  # at a position, so this site is the one that survives the walk into that call node.
  defp piped_site(sites, {{:., _, [_receiver, name]}, _meta, args} = right)
       when is_atom(name) and is_list(args),
       do: add_site(sites, right, length(args) + 1)

  defp piped_site(sites, {name, _meta, args} = right)
       when is_atom(name) and is_list(args) and name not in @not_calls do
    if sigil?(name), do: sites, else: add_site(sites, right, length(args) + 1)
  end

  defp piped_site(sites, _right), do: sites

  defp defaults({_name, _meta, args}) when is_list(args),
    do: for({:\\, _, [_arg, default]} <- args, do: default)

  defp defaults(_head), do: []

  defp add_site(sites, node, arity \\ nil) do
    case call_range(node) do
      nil ->
        sites

      {line, column, range} ->
        site = %{
          line: line,
          column: column,
          range: range,
          template: template(node),
          callee: callee(node, arity)
        }

        [site | sites]
    end
  end

  # The arity is the argument list's length, except for a capture, where the caller reads
  # it off the `/2` the source wrote and the name carries no arguments at all.
  defp callee({{:., _, [receiver, name]}, _meta, args}, nil) when is_atom(name) and is_list(args),
    do: %{module: receiver_name(receiver), name: name, arity: length(args)}

  defp callee({{:., _, [receiver, name]}, _meta, _args}, arity)
       when is_atom(name) and is_integer(arity),
       do: %{module: receiver_name(receiver), name: name, arity: arity}

  defp callee({name, _meta, args}, nil) when is_atom(name) and is_list(args),
    do: %{module: nil, name: name, arity: length(args)}

  defp callee({name, _meta, _args}, arity) when is_atom(name) and is_integer(arity),
    do: %{module: nil, name: name, arity: arity}

  defp callee(_node, _arity), do: nil

  # Only a receiver the source spells out as a module is recorded. `mod.f(x)` names a
  # module no parser can know, and a call placed by name against it would match anything;
  # `nil`, `true` and `false` are values, not the modules their text would name.
  defp receiver_name({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp receiver_name({:__block__, _meta, [atom]})
       when is_atom(atom) and atom not in [nil, true, false],
       do: inspect(atom)

  defp receiver_name(_expression), do: nil

  # `~H"""` content reaches the compiler with the heredoc's indentation stripped, starting on
  # the line below the sigil, which is where these file positions put it too.
  defp sigil_sites({:sigil_H, meta, [{:<<>>, str_meta, [content]}, _modifiers]}) do
    with line when is_integer(line) <- meta[:line],
         column when is_integer(column) <- meta[:column] do
      delimiter = meta[:delimiter] || str_meta[:delimiter]

      if delimiter in ~w(""" '''),
        do: template_sites(content, {line + 1, str_meta[:indentation] || 0}),
        else: inline_sigil_sites(content, line, column)
    else
      _ -> []
    end
  end

  # `Phoenix.Component.sigil_H/2` hands EEx `line: caller line + 1` and `indentation: 0`
  # whatever the delimiter, so the compiler reports the calls of a single-line `~H"..."` one
  # line below the sigil at their column within the content. `Grasp.Index.Join` keys a site
  # by line and column and renders its range, so the site carries the compiler's position as
  # the key and the file's own — three columns past the `~`, after the sigil name and its
  # opening quote — as the range the reader clicks. Both lists come from one function, so
  # they hold the same sites in the same order and zip.
  defp inline_sigil_sites(content, line, column) do
    keys = template_sites(content, {line + 1, 0})
    ranges = template_sites(content, {line, 0}, column + 3)

    Enum.zip_with(keys, ranges, &%{&1 | range: &2.range})
  end

  # The template a `render(conn, :show, …)` or `render(conn, "show.html", …)` call renders.
  defp template({{:., _, [_receiver, :render]}, _meta, [_first, second | _rest]}),
    do: template_name(second)

  defp template({:render, _meta, [_first, second | _rest]}), do: template_name(second)
  defp template(_node), do: nil

  defp template_name({:__block__, _meta, [name]}) when is_atom(name),
    do: template_name(Atom.to_string(name))

  defp template_name({:__block__, _meta, [name]}) when is_binary(name), do: template_name(name)
  defp template_name(name) when is_binary(name), do: String.replace_suffix(name, ".html", "")
  defp template_name(_other), do: nil

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
