defmodule GraspWeb.CardComponents do
  @moduledoc """
  One card on the canvas: the node the canvas drags, the card itself, and the stub shown
  for a function the index does not contain.

  A card carries no knowledge of what it calls beyond the edges leaving it. Each of those
  edges paints its own call site — the span in the body, or the button in the "Also calls"
  footer — with the edge's palette colour and the id of the card at the far end, so the
  connector layer can join the two without a second source of truth.
  """

  use GraspWeb, :html

  import GraspWeb.CommentComponents

  alias Grasp.Comments.Anchor
  alias Grasp.Diff
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
  attr :column, :integer, required: true
  attr :open_calls, :map, required: true
  attr :editor, :string, default: nil
  attr :callers_open, :integer, default: nil
  attr :selected, :boolean, default: false
  attr :comments, :map, doc: "every thread of the project, keyed by function id", default: %{}
  attr :composing, :map, doc: "the anchor a comment is being written at", default: nil
  attr :expanded_threads, :any, doc: "ids of the resolved threads shown in full", default: nil

  # The drag hook translates the node rather than the card, so the offset survives a
  # re-render: LiveView owns the card's attributes, and the node is where the hand-placed
  # position lives.
  def card_node(assigns) do
    card = Forest.card(assigns.forest, assigns.card_id)
    {dx, dy} = card.offset

    assigns = assign(assigns, card: card, dx: dx, dy: dy)

    ~H"""
    <div class="node" style={"--dx: #{@dx}px; --dy: #{@dy}px"}>
      <.card
        forest={@forest}
        index={@index}
        card={@card}
        column={@column}
        open_calls={@open_calls}
        editor={@editor}
        callers_open={@callers_open}
        selected={@selected}
        comments={@comments}
        composing={@composing}
        expanded_threads={@expanded_threads}
      />
    </div>
    """
  end

  attr :forest, Forest, required: true
  attr :index, Index, required: true
  attr :card, :map, required: true
  attr :column, :integer, required: true
  attr :open_calls, :map, required: true
  attr :editor, :string, default: nil
  attr :callers_open, :integer, default: nil
  attr :selected, :boolean, default: false
  attr :comments, :map, doc: "every thread of the project, keyed by function id", default: %{}
  attr :composing, :map, doc: "the anchor a comment is being written at", default: nil
  attr :expanded_threads, :any, doc: "ids of the resolved threads shown in full", default: nil

  def card(assigns) do
    case Index.fetch_function(assigns.index, assigns.card.function_id) do
      {:ok, record} -> function_card(assign(assigns, record: record))
      :error -> stub_card(assigns)
    end
  end

  attr :change, :string, default: nil

  @doc """
  The badge naming what a pull request did to a function: added, modified or removed.

  Renders nothing for a function the branch left alone, so a caller can hand it every
  record it lists without asking first.
  """
  def change_badge(assigns) do
    ~H"""
    <span
      :if={@change in ~w(added modified removed)}
      class="badge badge--change"
      data-change={@change}
    >
      {@change}
    </span>
    """
  end

  defp function_card(assigns) do
    %{forest: forest, index: index, card: card, record: record, comments: comments} = assigns

    external? = fn target -> match?(:error, Index.fetch_function(index, target)) end

    {dx, dy} = card.offset

    change = record["change"] || "unchanged"
    diffable? = Diff.diffable?(record)

    # A card holds its view across an index reload, so one opened on a diff can outlive the
    # diff itself — a rebase, or a base ref that moved. Nothing is left to show, and the
    # toggle that would switch back is gone with the diff, so the card reads as source
    # again rather than reporting a view it is not in.
    view = Forest.effective_view(card.view, diffable?)

    highlight_opts = [
      card_id: card.id,
      open_calls: assigns.open_calls,
      external?: external?,
      highlight: card.highlight
    ]

    lines =
      if view == :diff,
        do: Grasp.Highlight.diff_lines(record, highlight_opts),
        else: Grasp.Highlight.lines(record, highlight_opts)

    # A thread names a line, not a rendered one: the code under it moves, so where each one
    # belongs is decided against the record about to be drawn. Anything the anchor can no
    # longer find keeps its place in the footer instead of being dropped.
    placements =
      comments
      |> Map.get(record["id"], [])
      |> Enum.group_by(&Anchor.place(&1, record))

    assigns =
      assign(assigns,
        focused?: forest.focus == card.id,
        lines: lines,
        placed: Map.drop(placements, [:outdated, :orphan]),
        outdated: Map.get(placements, :outdated, []),
        expanded_threads: assigns.expanded_threads || MapSet.new(),
        dx: dx,
        dy: dy,
        change: change,
        diffable?: diffable?,
        stats: diffable? && Diff.stats(record["base_source"], record["source"]),
        callers: Index.callers(index, record["id"]),
        entries: Index.entry_points_for(index, record["id"]),
        signature: signature(record),
        signature_html: Grasp.Highlight.signature(record),
        callees: Forest.callees(forest, card.id),
        hidden_count: Forest.hidden_count(forest, card.id),
        view: view,
        gutter: gutter_columns(record),
        # A removed function's file and line are the base commit's: the line may hold
        # something else on this branch, or the file may be gone, so there is nothing to
        # open and the card prints the location as plain text.
        editor_href:
          !record["removed"] &&
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
      class={[
        "card",
        @focused? && "card--focused",
        @selected && "card--selected",
        @record["removed"] && "card--removed"
      ]}
      data-function-id={@record["id"]}
      data-focused={to_string(@focused?)}
      data-selected={to_string(@selected)}
      data-view={to_string(@view)}
      data-highlight-key={highlight_key(@card.highlight)}
      data-depth={@column}
      data-dx={@dx}
      data-dy={@dy}
    >
      <header class="card__header" phx-click="focus_card" phx-value-card={@card.id}>
        <.change_badge change={@change} />
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
        <span :if={@stats} class="card__stats">+{@stats.added} −{@stats.removed}</span>
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
            :if={@diffable?}
            id={"view-#{@card.id}"}
            class="card__view"
            phx-click="toggle_view"
            phx-value-card={@card.id}
            title="Show the diff against the base (d)"
          >
            {if @view == :source, do: "diff", else: "source"}
          </button>
          <button
            :if={@callees != []}
            class="card__collapse"
            phx-click="toggle_collapse"
            phx-value-card={@card.id}
            title="Collapse what only this card reaches (c)"
          >
            {if @card.collapsed, do: "▸ #{@hidden_count}", else: "▾"}
          </button>
          <button
            class="card__close"
            phx-click="close_card"
            phx-value-card={@card.id}
            title="Close (x) · Shift+x closes the chain"
          >
            ×
          </button>
        </div>
      </header>
      <p class="card__signature lumis" title={@signature}>{@signature_html}</p>
      <%!-- The lines are rendered one at a time so a thread can sit between two of them.
      Whitespace between the children here is ordinary white-space, which the body does not
      preserve — only the lines themselves are preformatted. --%>
      <div class="card__body lumis" style={"--gutter: #{@gutter}ch"}>
        <%= for line <- @lines do %>
          {raw(line.html)}<.thread
            :for={thread <- Map.get(@placed, {line.side, line.line}, [])}
            thread={thread}
            card_id={@card.id}
            expanded={MapSet.member?(@expanded_threads, thread.id)}
            composing={@composing}
          /><.composer
            :if={composing_at?(@composing, @card.id, line.side, line.line)}
            composing={@composing}
            card_id={@card.id}
          />
        <% end %>
      </div>
      <footer :if={@outdated != []} class="card__outdated">
        <.thread
          :for={thread <- @outdated}
          thread={thread}
          card_id={@card.id}
          expanded={MapSet.member?(@expanded_threads, thread.id)}
          composing={@composing}
          outdated
        />
      </footer>
      <footer :if={@record["hidden_calls"] != []} class="card__also">
        <span class="card__also-label">Also calls</span>
        <button
          :for={call <- @record["hidden_calls"]}
          class="also"
          phx-click="open_call"
          phx-value-card={@card.id}
          phx-value-target={call["target"]}
          {edge_attrs(@open_calls, call["target"])}
        >
          {call["target"]}
        </button>
      </footer>
    </article>
    """
  end

  # Where the composer for a new thread is drawn. A reply is not placed here: it belongs
  # inside the thread it answers, which renders it itself.
  defp composing_at?(
         %{card: card, side: side, line: line, reply_to: nil},
         card_id,
         line_side,
         number
       )
       when card == card_id and line == number,
       do: to_string(line_side) == side

  defp composing_at?(_composing, _card_id, _side, _number), do: false

  # Columns the gutter reserves: enough for the highest number the body prints — the span's
  # last line, which is also the highest the diff view prints, since a deleted line prints
  # none — and one more for the `+` that appears beside it on hover.
  defp gutter_columns(record) do
    last = record["span"]["end_line"] || record["span"]["start_line"] || 1
    max(4, String.length(Integer.to_string(last)) + 1)
  end

  # The footer button for a hidden call is marked exactly as the call spans in the body are,
  # so a call the graph has opened reads the same wherever the card shows it.
  defp edge_attrs(open_calls, target) do
    case Map.fetch(open_calls, target) do
      {:ok, %{to: to, color: color}} ->
        ["data-open": "true", "data-color": color, "data-edge-to": to]

      :error ->
        ["data-open": "false"]
    end
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
      class={["card", "stub", @focused? && "card--focused", @selected && "card--selected"]}
      data-function-id={@card.function_id}
      data-focused={to_string(@focused?)}
      data-selected={to_string(@selected)}
      data-depth={@column}
      data-dx={@dx}
      data-dy={@dy}
    >
      <header class="card__header" phx-click="focus_card" phx-value-card={@card.id}>
        <h2 class="card__title">{@card.function_id}</h2>
        <div class="card__tools">
          <button class="card__close" phx-click="close_card" phx-value-card={@card.id}>×</button>
        </div>
      </header>
      <p class="card__signature lumis" title={@card.function_id}>{@card.function_id}</p>
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

  @doc """
  The one line that heads a function as plain text: its definition, without the indentation
  it was written at and without a trailing `do`.

  The card renders the head highlighted, and carries this beside it as the title a pointer
  reads — an attribute holds text, not markup. A record with no definition line anywhere
  falls back to `Mod.fun/arity`, which is what a stub shows.
  """
  @spec signature(map()) :: String.t()
  def signature(record) do
    case Grasp.Highlight.signature_line(record) do
      {_line, text} -> text
      nil -> record["id"] || ""
    end
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

  # Call targets come from the index and from the browser, so concatenating them into a
  # module atom would let anyone grow the atom table one unknown name at a time.
  defp existing_module(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> :error
  end
end
