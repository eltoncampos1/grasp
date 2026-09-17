defmodule Grasp.Session.Forest do
  @moduledoc """
  The graph of cards a review session shows, as pure data with pure operations.

  One card per function. Opening a function already on screen focuses the card that shows
  it rather than cloning it, so a helper called from three places is one card with three
  edges arriving at it, and reading it once is reading it for every caller. `edges` are
  directed caller → callee. Each carries the raw call `target` the caller's source wrote —
  the spelling that identifies the call site inside the caller's body — and a `color` taken
  from an eight-entry palette in creation order, so a call site and the edge leaving it can
  be painted alike. At most one edge runs from one card to another, whichever call opened it,
  so mutual recursion is visibly two edges.
  Focus is a single card id; `offset` is a card's displacement in stage pixels from where
  the layout puts it, so a card dragged by hand keeps its place; `highlight` marks what to
  point at inside a card; `view` chooses whether a modified function reads as the source on
  the branch or as the diff against the base, and `context` whether that diff shows every
  line or only the changed hunks.

  ## Layout

  `layout/1` puts the cards in columns, callers to the left of what they call. Sources —
  cards nothing on screen calls — are column 0, and a card sits one column right of the
  furthest-right caller that reaches it. The columns are computed by a depth-first walk
  from the sources that refuses to re-enter a card already on its own stack: that edge is a
  back-edge, a recursive or mutually recursive call, and following it would never end. A
  graph made only of cycles has no source at all, so the lowest-id card no walk has reached
  is promoted to a source until every card is placed. Within a column, rows follow the
  callers: column 0 reads in id order, and every later column is ordered by the mean row of
  its callers in the column immediately left, so an edge crosses as little as possible. A
  card whose callers all sit further left has no mean and sorts last, by id.

  ## Groups

  A card belongs to at most one group, and a group is laid out on its own: `sections/1`
  runs the column algorithm over one group's visible cards at a time, seeing only the edges
  between them, so a member every caller of which sits in another section starts at column 0
  of its own. The sections read in group-id order and the cards in no group make a last,
  groupless one; `layout/1` is those sections flattened, which is why a column in it never
  mixes two sections and `depth/2` counts columns from the start of the card's own section.
  A card opened from a member of a group joins the group: `open_caller/4` and `open_child/4`
  give the card they create the group of the card it was opened from, so a caller is laid
  out one column left of its callee and a callee one column right of its parent, both inside
  the same frame. Only a card being created takes a group that way — opening a function
  already on screen adds an edge and leaves that card where it is.
  A group is a frame round cards and nothing else: it changes no edge, hides nothing, and is
  deleted the moment its last member leaves or is closed. A title is a label on that frame
  and may be absent — `new_group/3` makes a group of the cards in hand and asks for no name,
  while `group_cards/3` addresses one by title and so reaches only a titled group.

  ## Collapse

  Collapsing a card hides what only that card reaches. `hidden/1` walks from the sources
  but does not leave a collapsed card, so a callee that another visible card also calls
  stays on screen and only the part of the graph that hung off the collapsed card
  disappears — which is why `hidden_count/2` is a subtraction rather than a subtree size.
  `close/2` removes one card and the edges touching it, leaving its callees behind as new
  sources; `close_chain/2` is the sweeping version, taking with it everything that had no
  other way to be reached. A card that can reach the closed one is an ancestor rather than
  something it reached, and stays even when a cycle puts it downstream as well.
  """

  defstruct cards: %{},
            edges: [],
            groups: %{},
            focus: nil,
            next_id: 1,
            next_color: 0,
            next_group: 1

  @palette_size 8

  @type id :: pos_integer()
  @typedoc """
  What to point at inside a card: `%{"call" => function_id}` outlines a call, and
  `%{"lines" => [first, last]}` shades a range of lines. `nil` marks nothing.
  """
  @type highlight :: nil | %{optional(String.t()) => String.t() | [integer()]}
  @typedoc """
  How a card shows its function: `:auto` reads as the diff when the function has one and as
  the source otherwise, so a changed function opens on what changed; `:source` and `:diff`
  are the reviewer's explicit picks.
  """
  @type view :: :auto | :source | :diff
  @typedoc """
  How much of a function's diff a card shows: `:hunks` draws the changed lines with three
  lines of context on either side and folds the rest away, `:full` draws every line, and
  `:auto` folds a function longer than 100 lines and shows a shorter one whole. The source
  view ignores it.
  """
  @type context :: :auto | :hunks | :full
  @type card :: %{
          id: id(),
          function_id: String.t(),
          collapsed: boolean(),
          offset: {integer(), integer()},
          highlight: highlight(),
          view: view(),
          context: context(),
          group: group_id() | nil
        }
  @type group_id :: pos_integer()
  @typedoc "A group of cards, laid out as a section of its own; its title is nil when it has none."
  @type group :: %{id: group_id(), title: String.t() | nil}
  @typedoc """
  One group's cards in columns, or the ungrouped cards when `group` is nil. `columns` holds
  only the section's own visible cards.
  """
  @type section :: %{group: group() | nil, columns: [[id()]]}
  @typedoc """
  A call from one card to another: `target` is the caller's own spelling of the call, and
  `color` indexes the eight-colour palette the renderer paints the edge and its call site
  with.
  """
  @type edge :: %{from: id(), to: id(), target: String.t(), color: 0..7}
  @typedoc """
  One card in a flat graph description. `key` names the entry so a later entry can point at
  it through `parent_key`; the keys are the caller's own and mean nothing to the graph
  beyond that linking. Two entries naming the same function describe one card with two
  edges.
  """
  @type spec :: %{
          :key => String.t(),
          :function_id => String.t(),
          :parent_key => String.t() | nil,
          :opened_by => String.t() | nil,
          :highlight => highlight(),
          optional(:group) => String.t() | nil,
          optional(:context) => context()
        }
  @type t :: %__MODULE__{
          cards: %{id() => card()},
          edges: [edge()],
          groups: %{group_id() => group()},
          focus: id() | nil,
          next_id: id(),
          next_color: non_neg_integer(),
          next_group: group_id()
        }
  @type direction :: :parent | :child | :next | :prev
  @typedoc "A card as `to_map/1` writes it: its own fields, plus the ids at the far end of its edges."
  @type card_map :: %{String.t() => id() | String.t() | boolean() | highlight() | [id()]}
  @typedoc "An edge as `to_map/1` writes it: its ends, the call target and the palette index."
  @type edge_map :: %{String.t() => id() | String.t() | non_neg_integer()}
  @typedoc "A group as `to_map/1` writes it: its id, its title (null when it has none) and the cards in it."
  @type group_map :: %{String.t() => group_id() | String.t() | nil | [id()]}
  @typedoc "A section as `to_map/1` writes it: the group it belongs to, and its columns."
  @type section_map :: %{String.t() => group_id() | nil | [[id()]]}
  @typedoc "The whole graph as `to_map/1` writes it: focus, cards, edges, groups and columns."
  @type graph_map :: %{
          String.t() =>
            id() | nil | [card_map()] | [edge_map()] | [group_map()] | [section_map()] | [[id()]]
        }

  @doc "An empty graph."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The card with `id`, or nil."
  @spec card(t(), id()) :: card() | nil
  def card(%__MODULE__{} = forest, id), do: Map.get(forest.cards, id)

  @doc "The id of the card showing `function_id`, or nil when no card shows it."
  @spec find(t(), String.t()) :: id() | nil
  def find(%__MODULE__{} = forest, function_id) do
    Enum.find_value(forest.cards, fn {id, card} -> card.function_id == function_id && id end)
  end

  @doc """
  Opens `function_id` with no caller, or focuses the card already showing it. Returns the
  card id.
  """
  @spec open_root(t(), String.t()) :: {t(), id()}
  def open_root(%__MODULE__{} = forest, function_id) do
    {forest, id} = find_or_add(forest, function_id, nil)
    {%{forest | focus: id}, id}
  end

  @doc """
  Opens `function_id` as a callee of `parent_id` and focuses it, reusing the card that
  already shows it. Returns the callee's id, or nil if `parent_id` is unknown.

  `opened_by` is the call target the click named, which differs from `function_id` when the
  call went through a default-argument arity alias. A second call from the same parent to
  the same card adds no second edge: the first one already marks that call site.

  A card created here takes the parent's group, so a callee opened from inside a frame is
  laid out one column right of its parent in that frame. A card already on screen keeps the
  group it has.
  """
  @spec open_child(t(), id(), String.t(), String.t() | nil) :: {t(), id() | nil}
  def open_child(%__MODULE__{} = forest, parent_id, function_id, opened_by \\ nil) do
    case card(forest, parent_id) do
      nil ->
        {forest, nil}

      parent ->
        {forest, id} = find_or_add(forest, function_id, parent.group)
        forest = add_edge(forest, parent_id, id, opened_by || function_id)
        {%{forest | focus: id}, id}
    end
  end

  @doc """
  Opens `caller_function_id` as a caller of `card_id` and focuses it, reusing the card that
  already shows it. Returns the caller's id, or nil if `card_id` is unknown.

  `target` is the raw call target the caller writes for the call; it defaults to the card's
  own function id, which is what the caller writes whenever no arity alias is involved. The
  card itself does not move: it gains a caller to its left and keeps every other edge it
  had.

  A card created here takes the callee's group, so a caller opened from inside a frame is
  laid out one column left of the callee in that frame. A card already on screen keeps the
  group it has.
  """
  @spec open_caller(t(), id(), String.t(), String.t() | nil) :: {t(), id() | nil}
  def open_caller(%__MODULE__{} = forest, card_id, caller_function_id, target \\ nil) do
    case card(forest, card_id) do
      nil ->
        {forest, nil}

      card ->
        {forest, caller} = find_or_add(forest, caller_function_id, card.group)
        forest = add_edge(forest, caller, card_id, target || card.function_id)
        {%{forest | focus: caller}, caller}
    end
  end

  @doc """
  Removes `id` and every edge touching it; its callees stay and become sources.

  Focus moves to the closed card's first caller, then its first callee, then nowhere.
  """
  @spec close(t(), id()) :: t()
  def close(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil -> forest
      _card -> forest |> drop([id]) |> refocus_after(forest, id)
    end
  end

  @doc """
  Removes `id` together with every card that had no other way to be reached.

  A callee another visible card also calls stays; one that hung off `id` alone goes, and so
  does a cycle whose only way in was through `id`. Focus moves as it does for `close/2`,
  among the cards that survive.
  """
  @spec close_chain(t(), id()) :: t()
  def close_chain(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil ->
        forest

      _card ->
        ids = id_set(forest)

        # A card that can reach `id` is upstream of it, however many edges a cycle also
        # carries the other way, so the card opened first is never swept up by closing
        # something it called.
        downstream =
          forest
          |> reach(ids, callees(forest, id), false)
          |> MapSet.delete(id)
          |> MapSet.difference(ancestors(forest, ids, id))

        remaining = drop(forest, [id])
        left = id_set(remaining)
        # What `id` reached is kept only if something outside that reach still leads to it.
        # The walk starts outside and runs into the reach rather than the other way round,
        # so a card losing its last caller goes even though it now looks like a source.
        kept = reach(remaining, left, MapSet.difference(left, downstream), false)
        orphans = MapSet.intersection(downstream, MapSet.difference(left, kept))

        forest |> drop([id | MapSet.to_list(orphans)]) |> refocus_after(forest, id)
    end
  end

  @doc "Focuses `id` if it exists."
  @spec focus(t(), id()) :: t()
  def focus(%__MODULE__{} = forest, id),
    do: if(Map.has_key?(forest.cards, id), do: %{forest | focus: id}, else: forest)

  @doc "Collapses or expands `id`, hiding or showing what only it reaches."
  @spec toggle_collapse(t(), id()) :: t()
  def toggle_collapse(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil -> forest
      card -> put_card(forest, %{card | collapsed: not card.collapsed})
    end
  end

  @doc """
  The cards no collapsed card lets through: those reachable only by leaving a collapsed
  card.
  """
  @spec hidden(t()) :: MapSet.t(id())
  def hidden(%__MODULE__{} = forest) do
    ids = id_set(forest)
    MapSet.difference(ids, reach(forest, ids, sources(forest, ids), true))
  end

  @doc """
  How many cards collapsing `id` hides; 0 when `id` is not collapsed or not known.

  Measured by expanding `id` alone and comparing, so cards another collapsed card hides too
  are not counted twice.
  """
  @spec hidden_count(t(), id()) :: non_neg_integer()
  def hidden_count(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      %{collapsed: true} = card ->
        expanded = put_card(forest, %{card | collapsed: false})
        MapSet.size(hidden(forest)) - MapSet.size(hidden(expanded))

      _not_collapsed ->
        0
    end
  end

  @doc """
  Puts every card in `ids` into a group made for them, titled `title` or untitled when that
  is nil or blank. Returns the group's id.

  A group made here is always new, whatever it is called, so two of them may carry the same
  title and a group with no title at all is ordinary: the id is what names a group, and a
  title is a label over the frame. Cards leave whatever group they were in, unknown ids are
  ignored, and a group whose last member has left is deleted — so a call naming no card the
  graph knows leaves no group behind, though its id is spent, as ids are never reused.
  """
  @spec new_group(t(), String.t() | nil, [id()]) :: {t(), group_id()}
  def new_group(%__MODULE__{} = forest, title, ids) when is_list(ids) do
    {forest, group_id} = add_group(forest, trimmed_title(title))
    {forest |> regroup(ids, group_id) |> prune_groups(), group_id}
  end

  @doc """
  Puts every card in `ids` into the group titled `title`, creating it when no group carries
  that title. Returns the group's id.

  A card belongs to one group, so a card already in another leaves it; unknown ids are
  ignored, and a group whose last member has left is deleted. A call naming no card the
  graph knows therefore leaves no group behind, though its id is spent: group ids are never
  reused. Addressing a group by title reaches only a titled one — an untitled group is
  reached by its id, through `new_group/3`'s reply or `add_to_group/3` — so a blank title
  here frames the cards under a group of their own, as `new_group/3` does.
  """
  @spec group_cards(t(), String.t(), [id()]) :: {t(), group_id()}
  def group_cards(%__MODULE__{} = forest, title, ids) when is_binary(title) and is_list(ids) do
    {forest, group_id} = find_or_add_group(forest, trimmed_title(title))
    {forest |> regroup(ids, group_id) |> prune_groups(), group_id}
  end

  @doc """
  Retitles `group_id`, keeping its id and every card in it. A blank or nil title clears the
  title, leaving the group untitled rather than deleting it.

  An unknown group leaves the graph as it was. The title is stored trimmed, since
  `group_cards/3` finds a group by an exact title match and a padded one could never be
  found again. Renaming is what changes a title: naming the same
  cards in `group_cards/3` under another one builds a different group, and any id held
  elsewhere then points at a group that has gone.
  """
  @spec rename_group(t(), group_id(), String.t() | nil) :: t()
  def rename_group(%__MODULE__{} = forest, group_id, title) do
    case Map.get(forest.groups, group_id) do
      nil ->
        forest

      group ->
        group = %{group | title: trimmed_title(title)}
        %{forest | groups: Map.put(forest.groups, group_id, group)}
    end
  end

  @doc """
  Puts every card in `ids` into the group `group_id`, whatever that group is called.

  This joins a group by id and creates none, so an unknown group leaves the graph
  unchanged — the counterpart to `group_cards/3`, which finds or creates a group by title.
  A card already in another group leaves it, unknown ids are ignored, and a group whose last
  member has left is deleted.
  """
  @spec add_to_group(t(), group_id(), [id()]) :: t()
  def add_to_group(%__MODULE__{} = forest, group_id, ids) when is_list(ids) do
    if Map.has_key?(forest.groups, group_id),
      do: forest |> regroup(ids, group_id) |> prune_groups(),
      else: forest
  end

  @doc "Takes every card in `ids` out of its group, deleting a group left with no members."
  @spec ungroup_cards(t(), [id()]) :: t()
  def ungroup_cards(%__MODULE__{} = forest, ids) when is_list(ids),
    do: forest |> regroup(ids, nil) |> prune_groups()

  @doc "Deletes `group_id`, leaving its members in the graph with no group."
  @spec dissolve_group(t(), group_id()) :: t()
  def dissolve_group(%__MODULE__{} = forest, group_id) do
    forest |> regroup(members(forest, group_id), nil) |> prune_groups()
  end

  @doc "The group `group_id` names, or nil when the graph has no such group."
  @spec group(t(), group_id()) :: group() | nil
  def group(%__MODULE__{} = forest, group_id), do: Map.get(forest.groups, group_id)

  @doc "The group `id` belongs to; nil when it belongs to none, or is not a known card."
  @spec group_of(t(), id()) :: group() | nil
  def group_of(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      %{group: group_id} when is_integer(group_id) -> Map.get(forest.groups, group_id)
      _ungrouped_or_unknown -> nil
    end
  end

  @doc "The cards calling `id`, in the order their edges were opened."
  @spec callers(t(), id()) :: [id()]
  def callers(%__MODULE__{} = forest, id),
    do: for(%{from: from, to: ^id} <- forest.edges, do: from)

  @doc "The cards `id` calls, in the order their edges were opened."
  @spec callees(t(), id()) :: [id()]
  def callees(%__MODULE__{} = forest, id), do: for(%{from: ^id, to: to} <- forest.edges, do: to)

  @doc "The edges joining two visible cards, in the order they were opened."
  @spec edges(t()) :: [edge()]
  def edges(%__MODULE__{} = forest) do
    hidden = hidden(forest)
    Enum.reject(forest.edges, &(MapSet.member?(hidden, &1.from) or MapSet.member?(hidden, &1.to)))
  end

  @doc """
  The visible cards as one section per group, in group-id order, then the cards in no group.

  A section is laid out on its own: the columns come from its own cards and the edges
  between them, so a member reached only from another section heads a column of its own.
  The last section is left out when every visible card belongs to a group; a group keeps its
  section even when a collapse elsewhere hides all its members, and reads as having no
  columns at all.
  """
  @spec sections(t()) :: [section()]
  def sections(%__MODULE__{} = forest) do
    visible = MapSet.difference(id_set(forest), hidden(forest))
    members = Enum.group_by(visible, &card(forest, &1).group)

    sections =
      forest.groups
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&%{group: &1, columns: columns(forest, Map.get(members, &1.id, []))})

    case Map.get(members, nil, []) do
      [] -> sections
      ungrouped -> sections ++ [%{group: nil, columns: columns(forest, ungrouped)}]
    end
  end

  @doc """
  The visible cards in columns, callers left of what they call and each column in row
  order: the sections one after another, so a column belongs to one section only.
  """
  @spec layout(t()) :: [[id()]]
  def layout(%__MODULE__{} = forest), do: forest |> sections() |> Enum.flat_map(& &1.columns)

  @doc """
  Every visible card's column index within its own section, for a caller that would
  otherwise ask `depth/2` once per card and lay the whole graph out again each time.
  """
  @spec columns_of(t()) :: %{id() => non_neg_integer()}
  def columns_of(%__MODULE__{} = forest) do
    Enum.reduce(sections(forest), %{}, fn section, columns ->
      section.columns
      |> Enum.with_index()
      |> Enum.reduce(columns, fn {ids, index}, columns ->
        Enum.reduce(ids, columns, &Map.put(&2, &1, index))
      end)
    end)
  end

  @doc "The column `id` is laid out in inside its section; 0 when it is hidden or unknown."
  @spec depth(t(), id()) :: non_neg_integer()
  def depth(%__MODULE__{} = forest, id), do: Map.get(columns_of(forest), id, 0)

  @doc "Sets a card's layout offset in stage pixels; no-op on an unknown id."
  @spec move(t(), id(), {integer(), integer()}) :: t()
  def move(%__MODULE__{} = forest, id, {dx, dy}) when is_integer(dx) and is_integer(dy) do
    case card(forest, id) do
      nil -> forest
      card -> put_card(forest, %{card | offset: {dx, dy}})
    end
  end

  @doc """
  Adds `{dx, dy}` to the offset of every card in `group_id`, moving the group as one piece.

  The members keep their positions relative to one another, which is what makes the frame
  drawn round them travel unchanged. Deltas rather than an absolute offset, since the cards
  start from offsets of their own. An unknown group changes nothing.
  """
  @spec shift_group(t(), group_id(), {integer(), integer()}) :: t()
  def shift_group(%__MODULE__{} = forest, group_id, {dx, dy})
      when is_integer(dx) and is_integer(dy) do
    if Map.has_key?(forest.groups, group_id) do
      cards =
        Map.new(forest.cards, fn
          {id, %{group: ^group_id, offset: {x, y}} = card} ->
            {id, %{card | offset: {x + dx, y + dy}}}

          {id, card} ->
            {id, card}
        end)

      %{forest | cards: cards}
    else
      forest
    end
  end

  @doc "Clears every card's offset so the graph returns to its automatic layout."
  @spec reset_offsets(t()) :: t()
  def reset_offsets(%__MODULE__{} = forest) do
    %{forest | cards: Map.new(forest.cards, fn {id, card} -> {id, %{card | offset: {0, 0}}} end)}
  end

  @doc """
  Moves focus to the first caller, the first visible callee, or the neighbour in the same
  column. Focus stays put when there is nowhere to go.
  """
  @spec move_focus(t(), direction()) :: t()
  def move_focus(%__MODULE__{focus: nil} = forest, _direction) do
    case layout(forest) do
      [[first | _] | _] -> %{forest | focus: first}
      _empty -> forest
    end
  end

  def move_focus(%__MODULE__{} = forest, direction) do
    target =
      case direction do
        :parent -> forest |> visible(callers(forest, forest.focus)) |> List.first()
        :child -> forest |> visible(callees(forest, forest.focus)) |> List.first()
        :next -> neighbour(forest, 1)
        :prev -> neighbour(forest, -1)
      end

    if target, do: %{forest | focus: target}, else: forest
  end

  @doc "Sets `highlight` on `id`; unknown ids are ignored."
  @spec set_highlight(t(), id(), highlight()) :: t()
  def set_highlight(%__MODULE__{} = forest, id, highlight) do
    case card(forest, id) do
      nil -> forest
      card -> put_card(forest, %{card | highlight: highlight})
    end
  end

  @doc "Picks how `id` is shown; unknown ids are ignored."
  @spec set_view(t(), id(), view()) :: t()
  def set_view(%__MODULE__{} = forest, id, view) when view in [:auto, :source, :diff] do
    case card(forest, id) do
      nil -> forest
      card -> put_card(forest, %{card | view: view})
    end
  end

  @doc """
  Swaps `id` between its source and its diff. Only a card with a diff is ever toggled, so
  `:auto` counts as the diff it resolves to and flips to the source.
  """
  @spec toggle_view(t(), id()) :: t()
  def toggle_view(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil -> forest
      %{view: :source} -> set_view(forest, id, :diff)
      %{view: _diff_or_auto} -> set_view(forest, id, :source)
    end
  end

  @doc "The view a card renders in: `:auto` becomes the diff when `diffable?`, else the source."
  @spec effective_view(view(), boolean()) :: :source | :diff
  def effective_view(:auto, true), do: :diff
  def effective_view(:auto, false), do: :source
  def effective_view(view, _diffable?), do: view

  @doc "Picks how much of `id`'s diff is drawn; unknown ids are ignored."
  @spec set_context(t(), id(), context()) :: t()
  def set_context(%__MODULE__{} = forest, id, context)
      when context in [:auto, :hunks, :full] do
    case card(forest, id) do
      nil -> forest
      card -> put_card(forest, %{card | context: context})
    end
  end

  @doc """
  Swaps `id` between the changes alone and every line, `loc` being the length of the
  function it draws.

  A card left on `:auto` is toggled away from what it currently shows rather than from
  `:auto` itself, so the first press always changes what the reader is looking at.
  """
  @spec toggle_context(t(), id(), non_neg_integer()) :: t()
  def toggle_context(%__MODULE__{} = forest, id, loc) do
    case card(forest, id) do
      nil ->
        forest

      card ->
        case effective_context(card.context, loc) do
          :hunks -> set_context(forest, id, :full)
          :full -> set_context(forest, id, :hunks)
        end
    end
  end

  @doc """
  How much of a diff a card draws: `:auto` folds a function of more than 100 lines and
  shows a shorter one whole.

  A short function is read whole in about the space its hunks would take, and the fold row
  would cost more attention than the lines it saves.
  """
  @spec effective_context(context(), non_neg_integer()) :: :hunks | :full
  def effective_context(:auto, loc) when loc > 100, do: :hunks
  def effective_context(:auto, _loc), do: :full
  def effective_context(context, _loc), do: context

  @doc """
  Builds a graph from an ordered flat spec. A `parent_key` names an earlier entry, and the
  first entry's card takes the focus.

  Entries naming the same function describe one card, so a spec listing a helper under each
  of its callers draws one card with an edge from each, and the card keeps the highlight of
  whichever entry asked for one.

  An entry's `group` is a title rather than an id: entries carrying the same title land in
  one group, and the groups are created in the order the titles first appear.
  """
  @spec replace([spec()]) :: {:ok, t()} | {:error, {:unknown_parent, String.t()}}
  def replace(specs) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, new(), %{}, nil}, fn spec, {:ok, forest, keys, first} ->
      case open(forest, keys, spec) do
        {:ok, forest, id} ->
          # A later entry for the same function marks nothing of its own, so the highlight
          # an earlier entry asked for survives the card being named again.
          forest = if spec.highlight, do: set_highlight(forest, id, spec.highlight), else: forest

          forest =
            case Map.get(spec, :context) do
              nil -> forest
              context -> set_context(forest, id, context)
            end

          forest = join_group(forest, id, Map.get(spec, :group))
          {:cont, {:ok, forest, Map.put(keys, spec.key, id), first || id}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, forest, _keys, first} -> {:ok, %{forest | focus: first}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The graph as plain maps with string keys, the shape the MCP tools return.

  Cards read in id order and carry the ids they call and are called by; `edges`, `columns`
  and `sections` describe only what is visible, so a collapsed card's hidden part is absent
  from all three. `groups` reads in id order and names every member, hidden ones included,
  because a group is a fact about the cards rather than about the layout.
  """
  @spec to_map(t()) :: graph_map()
  def to_map(%__MODULE__{} = forest) do
    cards =
      forest.cards
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn card ->
        %{
          "id" => card.id,
          "function_id" => card.function_id,
          "collapsed" => card.collapsed,
          "view" => Atom.to_string(card.view),
          "context" => Atom.to_string(card.context),
          "highlight" => card.highlight,
          "group" => card.group,
          "callers" => callers(forest, card.id),
          "callees" => callees(forest, card.id)
        }
      end)

    edges =
      Enum.map(edges(forest), fn edge ->
        %{"from" => edge.from, "to" => edge.to, "target" => edge.target, "color" => edge.color}
      end)

    groups =
      forest.groups
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(
        &%{"id" => &1.id, "title" => &1.title, "cards" => forest |> members(&1.id) |> Enum.sort()}
      )

    sections = sections(forest)

    %{
      "focus" => forest.focus,
      "cards" => cards,
      "edges" => edges,
      "groups" => groups,
      "sections" =>
        Enum.map(sections, &%{"group" => &1.group && &1.group.id, "columns" => &1.columns}),
      "columns" => Enum.flat_map(sections, & &1.columns)
    }
  end

  # The column algorithm over `ids` alone: a card is a source when no caller of it is in
  # `ids`, so a section reads as if the rest of the graph were not there.
  defp columns(forest, ids) do
    ids = MapSet.new(ids)

    columns =
      forest
      |> sources(ids)
      |> Enum.reduce(%{}, &column(forest, ids, &1, 0, MapSet.new(), &2))
      |> Enum.group_by(fn {_id, column} -> column end, fn {id, _column} -> id end)

    columns
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce([], &order(forest, columns, &1, &2))
    |> Enum.reverse()
  end

  # There is no untitled group to find: a title is what `group_cards/3` addresses a group by,
  # so a blank one asks for a frame rather than for a particular frame.
  defp find_or_add_group(forest, nil), do: add_group(forest, nil)

  defp find_or_add_group(forest, title) do
    case Enum.find(forest.groups, fn {_id, group} -> group.title == title end) do
      {id, _group} -> {forest, id}
      nil -> add_group(forest, title)
    end
  end

  defp add_group(forest, title) do
    id = forest.next_group
    group = %{id: id, title: title}
    {%{forest | groups: Map.put(forest.groups, id, group), next_group: id + 1}, id}
  end

  # A title is stored trimmed and a blank one is no title at all, so a frame is never drawn
  # with a name made of spaces and `group_cards/3`'s exact match has one spelling to find.
  defp trimmed_title(nil), do: nil

  defp trimmed_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp regroup(forest, ids, group_id) do
    cards =
      Enum.reduce(ids, forest.cards, fn id, cards ->
        case Map.fetch(cards, id) do
          {:ok, card} -> Map.put(cards, id, %{card | group: group_id})
          :error -> cards
        end
      end)

    %{forest | cards: cards}
  end

  defp members(forest, group_id),
    do: for({id, %{group: ^group_id}} <- forest.cards, do: id)

  defp prune_groups(forest) do
    taken = MapSet.new(Map.values(forest.cards), & &1.group)

    %{
      forest
      | groups: Map.filter(forest.groups, fn {id, _group} -> MapSet.member?(taken, id) end)
    }
  end

  # An entry naming no group, or naming one with nothing but spaces in it, says nothing about
  # the card's group, the way an entry with no highlight leaves standing the one an earlier
  # entry asked for.
  defp join_group(forest, id, title) do
    case trimmed_title(title) do
      nil ->
        forest

      trimmed ->
        {forest, _group_id} = group_cards(forest, trimmed, [id])
        forest
    end
  end

  defp open(forest, _keys, %{parent_key: nil} = spec) do
    {forest, id} = open_root(forest, spec.function_id)
    {:ok, forest, id}
  end

  defp open(forest, keys, spec) do
    case Map.fetch(keys, spec.parent_key) do
      {:ok, parent_id} ->
        {forest, id} = open_child(forest, parent_id, spec.function_id, spec.opened_by)
        {:ok, forest, id}

      :error ->
        {:error, {:unknown_parent, spec.parent_key}}
    end
  end

  defp find_or_add(forest, function_id, group) do
    case find(forest, function_id) do
      nil -> add_card(forest, function_id, group)
      id -> {forest, id}
    end
  end

  defp add_card(forest, function_id, group) do
    id = forest.next_id

    card = %{
      id: id,
      function_id: function_id,
      collapsed: false,
      offset: {0, 0},
      highlight: nil,
      view: :auto,
      context: :auto,
      group: group
    }

    {%{forest | cards: Map.put(forest.cards, id, card), next_id: id + 1}, id}
  end

  defp add_edge(forest, from, to, target) do
    if Enum.any?(forest.edges, &(&1.from == from and &1.to == to)) do
      forest
    else
      edge = %{from: from, to: to, target: target, color: forest.next_color}

      %{
        forest
        | edges: forest.edges ++ [edge],
          next_color: rem(forest.next_color + 1, @palette_size)
      }
    end
  end

  defp put_card(forest, card), do: %{forest | cards: Map.put(forest.cards, card.id, card)}

  defp drop(forest, ids) do
    dropped = MapSet.new(ids)

    prune_groups(%{
      forest
      | cards: Map.drop(forest.cards, ids),
        edges:
          Enum.reject(
            forest.edges,
            &(MapSet.member?(dropped, &1.from) or MapSet.member?(dropped, &1.to))
          )
    })
  end

  defp refocus_after(forest, before, id) do
    focus =
      Enum.find(callers(before, id) ++ callees(before, id), &Map.has_key?(forest.cards, &1))

    %{forest | focus: focus}
  end

  defp id_set(forest), do: forest.cards |> Map.keys() |> MapSet.new()

  defp callerless(forest, ids) do
    ids
    |> Enum.filter(fn id ->
      forest |> callers(id) |> Enum.all?(&(not MapSet.member?(ids, &1)))
    end)
    |> Enum.sort()
  end

  # Every card has to land in a column, so a group of cards that only call each other — no
  # card in it is called from outside — elects its lowest id as the way in.
  defp sources(forest, ids) do
    forest |> callerless(ids) |> grow(forest, ids)
  end

  defp grow(sources, forest, ids) do
    case ids |> MapSet.difference(reach(forest, ids, sources, false)) |> Enum.sort() do
      [] -> sources
      [id | _rest] -> [id | sources] |> Enum.sort() |> grow(forest, ids)
    end
  end

  defp reach(forest, ids, starts, collapse?),
    do: walk(forest, ids, starts, &callees/2, collapse?)

  # The same walk with the edges read backwards: everything that can reach `id`.
  defp ancestors(forest, ids, id),
    do: forest |> walk(ids, callers(forest, id), &callers/2, false) |> MapSet.delete(id)

  defp walk(forest, ids, starts, next, collapse?) do
    Enum.reduce(starts, MapSet.new(), &visit(forest, ids, &1, next, collapse?, &2))
  end

  defp visit(forest, ids, id, next, collapse?, seen) do
    cond do
      MapSet.member?(seen, id) or not MapSet.member?(ids, id) ->
        seen

      collapse? and card(forest, id).collapsed ->
        MapSet.put(seen, id)

      true ->
        seen = MapSet.put(seen, id)
        Enum.reduce(next.(forest, id), seen, &visit(forest, ids, &1, next, collapse?, &2))
    end
  end

  # A card already placed further right stays there: its column is one past the caller that
  # reaches it from furthest right, and an edge back into the walk's own stack is a
  # recursive call, which names no column at all.
  defp column(forest, visible, id, column, stack, columns) do
    if Map.get(columns, id, -1) >= column do
      columns
    else
      columns = Map.put(columns, id, column)
      stack = MapSet.put(stack, id)

      forest
      |> callees(id)
      |> Enum.filter(&(MapSet.member?(visible, &1) and not MapSet.member?(stack, &1)))
      |> Enum.reduce(columns, &column(forest, visible, &1, column + 1, stack, &2))
    end
  end

  defp order(_forest, columns, 0, _ordered), do: [columns |> Map.get(0, []) |> Enum.sort()]

  defp order(forest, columns, index, [previous | _rest] = ordered) do
    rows = previous |> Enum.with_index() |> Map.new()

    column =
      columns
      |> Map.get(index, [])
      |> Enum.sort_by(fn id ->
        {forest |> callers(id) |> Enum.flat_map(&List.wrap(Map.get(rows, &1))) |> mean(), id}
      end)

    [column | ordered]
  end

  # A card reached only by a skip-level edge has no row to follow and sorts after the cards
  # that do.
  defp mean([]), do: :infinity
  defp mean(rows), do: Enum.sum(rows) / length(rows)

  defp visible(forest, ids) do
    hidden = hidden(forest)
    Enum.reject(ids, &MapSet.member?(hidden, &1))
  end

  defp neighbour(forest, step) do
    column = forest |> layout() |> Enum.find([], &(forest.focus in &1))

    case Enum.find_index(column, &(&1 == forest.focus)) do
      nil -> nil
      index when index + step < 0 -> nil
      index -> Enum.at(column, index + step)
    end
  end
end
