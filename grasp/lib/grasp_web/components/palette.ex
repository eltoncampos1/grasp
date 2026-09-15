defmodule GraspWeb.Palette do
  @moduledoc """
  The Cmd+K function palette: a `<dialog>` with a search input and ranked results. The
  `Palette` JS hook opens it, moves the selection with the arrow keys and reports the
  choice with `palette_open`; the server searches on every change and closes the dialog
  after opening a card.
  """

  use GraspWeb, :html

  attr :query, :string, required: true
  attr :results, :list, required: true

  def palette(assigns) do
    ~H"""
    <dialog id="palette" class="palette" phx-hook="Palette">
      <form
        id="palette-form"
        phx-change="palette_search"
        phx-submit="palette_submit"
        autocomplete="off"
      >
        <input
          type="text"
          name="q"
          value={@query}
          placeholder="Type a function name… (Enter opens, Shift+Enter opens under the focused card)"
          phx-debounce="80"
          autofocus
        />
      </form>
      <ul id="palette-results" class="palette__results">
        <li
          :for={{fun, i} <- Enum.with_index(@results)}
          data-id={fun["id"]}
          aria-selected={to_string(i == 0)}
        >
          <button
            type="button"
            class="palette__item"
            phx-click="palette_open"
            phx-value-id={fun["id"]}
            phx-value-child="false"
          >
            <span class="palette__id">{fun["id"]}</span>
            <span class="palette__meta">{fun["kind"]} · {fun["file"]}</span>
          </button>
        </li>
      </ul>
    </dialog>
    """
  end
end
