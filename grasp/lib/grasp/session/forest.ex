defmodule Grasp.Session.Forest do
  @moduledoc """
  The tree of cards a review session shows, as pure data with pure operations.

  A card shows one function. Cards form a forest: `roots` are the entry cards in column
  zero, and each card lists its `children` — callees opened from it. `opened_by` records
  which call target opened a card, so the parent can mark that call while the child is
  open. Focus is a single card id. Closing a card removes its subtree; collapsing hides
  it. Opening a caller from a root re-parents the root under the caller; from a non-root
  card it starts a new root tree so the original branch is left intact.
  """

  defstruct roots: [], cards: %{}, focus: nil, next_id: 1

  @type id :: pos_integer()
  @type card :: %{
          id: id(),
          function_id: String.t(),
          parent_id: id() | nil,
          children: [id()],
          opened_by: String.t() | nil,
          collapsed: boolean()
        }
  @type t :: %__MODULE__{
          roots: [id()],
          cards: %{id() => card()},
          focus: id() | nil,
          next_id: id()
        }
  @type direction :: :parent | :child | :next | :prev

  @doc "An empty forest."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The card with `id`, or nil."
  @spec card(t(), id()) :: card() | nil
  def card(%__MODULE__{} = forest, id), do: Map.get(forest.cards, id)

  @doc "Whether `id` is a root card."
  @spec root?(t(), id()) :: boolean()
  def root?(%__MODULE__{} = forest, id), do: id in forest.roots

  @doc "Number of ancestors of `id`."
  @spec depth(t(), id()) :: non_neg_integer()
  def depth(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      %{parent_id: nil} -> 0
      %{parent_id: parent} -> 1 + depth(forest, parent)
      nil -> 0
    end
  end

  @doc "Number of descendants of `id`."
  @spec subtree_size(t(), id()) :: non_neg_integer()
  def subtree_size(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil ->
        0

      %{children: children} ->
        length(children) + Enum.sum(Enum.map(children, &subtree_size(forest, &1)))
    end
  end

  @doc "Appends a new root showing `function_id` and focuses it."
  @spec open_root(t(), String.t()) :: {t(), id()}
  def open_root(%__MODULE__{} = forest, function_id) do
    {forest, id} = add_card(forest, function_id, nil, nil)
    {%{forest | roots: forest.roots ++ [id], focus: id}, id}
  end

  @doc """
  Opens `function_id` as a child of `parent_id`, or focuses the existing child that shows
  it. Returns the child id, or nil if `parent_id` is unknown.

  `opened_by` is the call target the click named, which differs from `function_id` when
  the call went through a default-argument arity alias.
  """
  @spec open_child(t(), id(), String.t(), String.t() | nil) :: {t(), id() | nil}
  def open_child(%__MODULE__{} = forest, parent_id, function_id, opened_by \\ nil) do
    parent = card(forest, parent_id)

    existing =
      parent && Enum.find(parent.children, &(card(forest, &1).function_id == function_id))

    cond do
      is_nil(parent) ->
        {forest, nil}

      existing ->
        {%{forest | focus: existing}, existing}

      true ->
        {forest, id} = add_card(forest, function_id, parent_id, opened_by || function_id)
        parent = %{parent | children: parent.children ++ [id]}
        {%{forest | cards: Map.put(forest.cards, parent_id, parent), focus: id}, id}
    end
  end

  @doc """
  Opens `caller_id` as the caller of `card_id`. On a root, the caller becomes the new root
  with the card as its child; otherwise a new root tree `caller → function` is opened.
  Returns the new root id, or nil if `card_id` is unknown.
  """
  @spec open_caller(t(), id(), String.t()) :: {t(), id() | nil}
  def open_caller(%__MODULE__{} = forest, card_id, caller_id) do
    case card(forest, card_id) do
      nil ->
        {forest, nil}

      card ->
        if root?(forest, card_id) do
          {forest, new_root} = add_card(forest, caller_id, nil, nil)
          caller = %{Map.fetch!(forest.cards, new_root) | children: [card_id]}
          card = %{card | parent_id: new_root, opened_by: card.function_id}
          roots = Enum.map(forest.roots, &if(&1 == card_id, do: new_root, else: &1))
          cards = forest.cards |> Map.put(new_root, caller) |> Map.put(card_id, card)
          {%{forest | roots: roots, cards: cards, focus: new_root}, new_root}
        else
          {forest, new_root} = open_root(forest, caller_id)
          {forest, _copy} = open_child(forest, new_root, card.function_id)
          {%{forest | focus: new_root}, new_root}
        end
    end
  end

  @doc "Removes `id` and its subtree; focus moves to the parent (or nil for a root)."
  @spec close(t(), id()) :: t()
  def close(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil ->
        forest

      card ->
        removed = [id | descendants(forest, id)]
        cards = Map.drop(forest.cards, removed)

        cards =
          case card.parent_id do
            nil ->
              cards

            parent_id ->
              Map.update!(cards, parent_id, &%{&1 | children: List.delete(&1.children, id)})
          end

        focus = if forest.focus in removed, do: card.parent_id, else: forest.focus
        %{forest | roots: List.delete(forest.roots, id), cards: cards, focus: focus}
    end
  end

  @doc "Focuses `id` if it exists."
  @spec focus(t(), id()) :: t()
  def focus(%__MODULE__{} = forest, id),
    do: if(Map.has_key?(forest.cards, id), do: %{forest | focus: id}, else: forest)

  @doc "Shows or hides the subtree of `id`."
  @spec toggle_collapse(t(), id()) :: t()
  def toggle_collapse(%__MODULE__{} = forest, id) do
    case card(forest, id) do
      nil ->
        forest

      card ->
        %{forest | cards: Map.put(forest.cards, id, %{card | collapsed: not card.collapsed})}
    end
  end

  @doc "Moves focus to the parent, first visible child, next or previous sibling."
  @spec move_focus(t(), direction()) :: t()
  def move_focus(%__MODULE__{focus: nil, roots: [first | _]} = forest, _dir),
    do: %{forest | focus: first}

  def move_focus(%__MODULE__{focus: nil} = forest, _dir), do: forest

  def move_focus(%__MODULE__{} = forest, dir) do
    card = Map.fetch!(forest.cards, forest.focus)

    target =
      case dir do
        :parent -> card.parent_id
        :child -> if card.collapsed, do: nil, else: List.first(card.children)
        :next -> neighbour(siblings(forest, card), card.id, 1)
        :prev -> neighbour(siblings(forest, card), card.id, -1)
      end

    if target, do: %{forest | focus: target}, else: forest
  end

  defp siblings(forest, %{parent_id: nil}), do: forest.roots
  defp siblings(forest, %{parent_id: parent_id}), do: Map.fetch!(forest.cards, parent_id).children

  defp neighbour(list, id, offset) do
    index = Enum.find_index(list, &(&1 == id)) + offset
    if index >= 0, do: Enum.at(list, index)
  end

  defp descendants(forest, id) do
    children = card(forest, id).children
    children ++ Enum.flat_map(children, &descendants(forest, &1))
  end

  defp add_card(forest, function_id, parent_id, opened_by) do
    id = forest.next_id

    card = %{
      id: id,
      function_id: function_id,
      parent_id: parent_id,
      children: [],
      opened_by: opened_by,
      collapsed: false
    }

    {%{forest | cards: Map.put(forest.cards, id, card), next_id: id + 1}, id}
  end
end
