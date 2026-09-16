defmodule GraspWeb.CardComponents do
  @moduledoc """
  The card tree: a recursive node component laying out a card and its children, the card
  itself, and the stub shown for a function the index does not contain.
  """

  use GraspWeb, :html

  alias Grasp.Index
  alias Grasp.Session.Forest

  @stdlib_apps [:elixir, :logger, :eex, :ex_unit, :mix, :iex]
  @badge_labels %{
    "live_route" => "live route",
    "oban_worker" => "worker",
    "live_view" => "live view",
    "live_component" => "component",
    "genserver" => "GenServer"
  }
  @function_id ~r/^([A-Z][\w.]*)\.([^.\/]+)\/(\d+)$/

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card_id, :integer, required: true
  attr :editor, :string, default: nil
  attr :callers_open, :integer, default: nil

  # The offset moves the whole node, not the card alone, so a card dragged by hand takes
  # the branch it opened with it rather than leaving its children behind.
  def card_node(assigns) do
    card = Forest.card(assigns.forest, assigns.card_id)
    {dx, dy} = card.offset

    assigns =
      assign(assigns,
        card: card,
        depth: Forest.depth(assigns.forest, assigns.card_id),
        dx: dx,
        dy: dy
      )

    ~H"""
    <div class="node" style={"--dx: #{@dx}px; --dy: #{@dy}px"}>
      <.card
        forest={@forest}
        index={@index}
        card={@card}
        depth={@depth}
        editor={@editor}
        callers_open={@callers_open}
      />
      <div
        :if={@card.children != [] and not @card.collapsed}
        class="node__children"
        id={"card-#{@card.id}-children"}
      >
        <.card_node
          :for={child <- @card.children}
          forest={@forest}
          index={@index}
          card_id={child}
          editor={@editor}
          callers_open={@callers_open}
        />
      </div>
    </div>
    """
  end

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card, :map, required: true
  attr :depth, :integer, required: true
  attr :editor, :string, default: nil
  attr :callers_open, :integer, default: nil

  def card(assigns) do
    case Index.fetch_function(assigns.index, assigns.card.function_id) do
      {:ok, record} -> function_card(assign(assigns, record: record))
      :error -> stub_card(assigns)
    end
  end

  defp function_card(assigns) do
    %{forest: forest, index: index, card: card, record: record} = assigns

    open_targets =
      for child <- card.children,
          c = Forest.card(forest, child),
          alias_id <- arity_aliases(index, c.function_id),
          do: alias_id

    external? = fn target -> match?(:error, Index.fetch_function(index, target)) end

    {dx, dy} = card.offset

    assigns =
      assign(assigns,
        focused?: forest.focus == card.id,
        dx: dx,
        dy: dy,
        callers: Index.callers(index, record["id"]),
        entries: Index.entry_points_for(index, record["id"]),
        subtree: Forest.subtree_size(forest, card.id),
        body:
          Grasp.Highlight.render(record,
            card_id: card.id,
            open_targets: open_targets,
            external?: external?,
            highlight: card.highlight
          ),
        editor_href:
          editor_url(
            assigns.editor,
            index.project["root"],
            record["file"],
            record["span"]["start_line"]
          )
      )

    ~H"""
    <article
      id={"card-#{@card.id}"}
      class={["card", @focused? && "card--focused"]}
      data-function-id={@record["id"]}
      data-focused={to_string(@focused?)}
      data-highlight-key={highlight_key(@card.highlight)}
      data-depth={@depth}
      data-dx={@dx}
      data-dy={@dy}
    >
      <header class="card__header" phx-click="focus_card" phx-value-card={@card.id}>
        <span
          :for={entry <- @entries}
          class={["badge", "badge--#{entry["kind"]}"]}
          title={entry["target"]}
        >
          {badge_label(entry)}
        </span>
        <h2 class="card__title">
          <span class="card__module">{@record["module"]}.</span><span class="card__fn">{@record[
            "name"
          ]}/{@record["arity"]}</span>
          <span class="card__kind">{@record["kind"]}</span>
        </h2>
        <div class="card__tools">
          <a :if={@editor_href} class="card__file" href={@editor_href}>
            {@record["file"]}:{@record["span"]["start_line"]}
          </a>
          <span :if={!@editor_href} class="card__file">
            {@record["file"]}:{@record["span"]["start_line"]}
          </span>
          <div :if={@callers != []} class="card__callers">
            <button
              class="card__callers-toggle"
              phx-click="toggle_callers"
              phx-value-card={@card.id}
              aria-expanded={to_string(@callers_open == @card.id)}
            >
              callers ({length(@callers)})
            </button>
            <ul :if={@callers_open == @card.id}>
              <li :for={caller <- @callers}>
                <button
                  class="caller"
                  phx-click="open_caller"
                  phx-value-card={@card.id}
                  phx-value-caller={caller}
                >
                  {caller}
                </button>
              </li>
            </ul>
          </div>
          <button
            :if={@card.children != []}
            class="card__collapse"
            phx-click="toggle_collapse"
            phx-value-card={@card.id}
            title="Collapse subtree"
          >
            {if @card.collapsed, do: "▸ #{@subtree}", else: "▾"}
          </button>
          <button
            class="card__close"
            phx-click="close_card"
            phx-value-card={@card.id}
            title="Close (x)"
          >
            ×
          </button>
        </div>
      </header>
      <pre class="card__body lumis">{@body}</pre>
      <footer :if={@record["hidden_calls"] != []} class="card__also">
        <span class="card__also-label">Also calls</span>
        <button
          :for={call <- @record["hidden_calls"]}
          class="also"
          phx-click="open_call"
          phx-value-card={@card.id}
          phx-value-target={call["target"]}
        >
          {call["target"]}
        </button>
      </footer>
    </article>
    """
  end

  # The canvas reveals a card again when this key changes, so a highlight pushed onto the
  # card that already has focus is still panned to.
  defp highlight_key(%{"call" => target}), do: "call:#{target}"
  defp highlight_key(%{"lines" => [first, last]}), do: "lines:#{first}-#{last}"
  defp highlight_key(_highlight), do: nil

  # A callback entry is labelled with the function it is, which the card title already
  # says; the kind is the part the badge adds, spelled the way a reader would say it
  # rather than the way the index stores it. A route's path is the one thing neither the
  # title nor the body carries, so it is shown in full.
  defp badge_label(%{"kind" => "route", "label" => label}), do: label
  defp badge_label(%{"kind" => kind}), do: Map.get(@badge_labels, kind, kind)

  defp stub_card(assigns) do
    {dx, dy} = assigns.card.offset

    assigns =
      assign(assigns,
        focused?: assigns.forest.focus == assigns.card.id,
        dx: dx,
        dy: dy,
        docs: hexdocs_url(assigns.card.function_id),
        stale?: indexed_module?(assigns.index, assigns.card.function_id)
      )

    ~H"""
    <article
      id={"card-#{@card.id}"}
      class={["card", "stub", @focused? && "card--focused"]}
      data-function-id={@card.function_id}
      data-focused={to_string(@focused?)}
      data-depth={@depth}
      data-dx={@dx}
      data-dy={@dy}
    >
      <header class="card__header" phx-click="focus_card" phx-value-card={@card.id}>
        <h2 class="card__title">{@card.function_id}</h2>
        <button class="card__close" phx-click="close_card" phx-value-card={@card.id}>×</button>
      </header>
      <p :if={@stale?} class="stub__text">
        No longer in the index — renamed or removed since it was written.
      </p>
      <p :if={!@stale?} class="stub__text">
        Not in the index (a dependency or the standard library).
      </p>
      <a :if={@docs} class="stub__docs" href={@docs} target="_blank" rel="noopener">Open on hexdocs</a>
    </article>
    """
  end

  @doc "Editor deep link for `file:line` under `root`, or nil when no editor is configured."
  @spec editor_url(String.t() | nil, String.t() | nil, String.t(), pos_integer()) ::
          String.t() | nil
  def editor_url(nil, _root, _file, _line), do: nil
  def editor_url(_editor, nil, _file, _line), do: nil

  def editor_url(editor, root, file, line) do
    path = Path.join(root, file)

    case editor do
      "vscode" -> "vscode://file/#{encode_path(path)}:#{line}"
      "cursor" -> "cursor://file/#{encode_path(path)}:#{line}"
      "zed" -> "zed://file/#{encode_path(path)}:#{line}"
      "idea" -> "idea://open?file=#{URI.encode_www_form(path)}&line=#{line}"
      _ -> nil
    end
  end

  # A space or an ampersand in a project path would otherwise truncate the link the browser
  # hands the editor; the separators have to survive, so each segment is encoded on its own.
  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  @doc "hexdocs URL for a standard-library function id, or nil for anything else."
  @spec hexdocs_url(term()) :: String.t() | nil
  def hexdocs_url(function_id) when not is_binary(function_id), do: nil

  def hexdocs_url(function_id) do
    with [_, module, name, arity] <- Regex.run(@function_id, function_id),
         {:ok, mod} <- existing_module(module),
         {:module, ^mod} <- Code.ensure_loaded(mod),
         {:ok, app} when app in @stdlib_apps <- :application.get_application(mod) do
      "https://hexdocs.pm/#{app}/#{module}.html##{name}/#{arity}"
    else
      _ -> nil
    end
  end

  # A card opened before the index was rewritten may show a function the project no longer
  # defines; its module still being indexed is what separates that from a dependency.
  defp indexed_module?(%Index{} = index, function_id) do
    case module_of(function_id) do
      nil -> false
      module -> Enum.any?(Index.modules(index), &(&1["name"] == module))
    end
  end

  defp module_of(function_id) when is_binary(function_id) do
    case Regex.run(@function_id, function_id) do
      [_, module, _name, _arity] -> module
      nil -> nil
    end
  end

  defp module_of(_function_id), do: nil

  # Every arity a definition answers to, so a call written against a default-argument
  # alias is marked as open even though the card shows the defining arity.
  defp arity_aliases(%Index{} = index, function_id) do
    case Index.fetch_function(index, function_id) do
      {:ok, record} ->
        for arity <- record["arities"] || List.wrap(record["arity"]),
            do: "#{record["module"]}.#{record["name"]}/#{arity}"

      :error ->
        [function_id]
    end
  end

  # Call targets come from the index and from the browser, so concatenating them into a
  # module atom would let anyone grow the atom table one unknown name at a time.
  defp existing_module(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> :error
  end
end
