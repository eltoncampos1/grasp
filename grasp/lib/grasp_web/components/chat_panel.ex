defmodule GraspWeb.ChatPanel do
  @moduledoc """
  The chat panel: the review agent's transcript, floating over the canvas.

  Everything it draws comes from the agent view the LiveView holds — whether the panel is
  open, the entries, whether a run is live — so a reload or a second tab rejoins the
  conversation mid-run rather than starting from an empty box. The one thing the client owns
  is the text being typed: the prompt carries `phx-update="ignore"` so that a patch landing
  while it is unfocused — one arrives per line of CLI output — cannot reset a half-written
  draft, and the `Chat` hook, not a re-render, clears it after a submit.

  An assistant turn is Markdown: `GraspWeb.ChatMarkdown` renders it server-side, sanitised,
  with its code fences highlighted and every function id the index holds drawn as a button
  that opens that function's card. A user's turn is the text they typed.

  A failed run is the one case where the transcript is not enough: the CLI explains itself
  on stderr, which the runner collects into `log`, so the log is offered beside an error.

  The settings row carries the two choices a run is made under — which model the CLI runs,
  and whether the agent may only read or may also edit files and run mix. Both are the
  agent's state rather than the panel's, so a second tab shows the mode the run will use.
  """

  use GraspWeb, :html

  alias GraspWeb.ChatMarkdown

  attr :open?, :boolean, required: true
  attr :agent, :map, required: true
  attr :index, :map, default: nil
  attr :error, :string, default: nil

  def chat_panel(assigns) do
    ~H"""
    <aside id="chat" class="chat" phx-hook="Chat" hidden={!@open?} aria-label="Agent chat">
      <div class="chat__log" id="chat-log" aria-live="polite">
        <%= for row <- rows(@agent.entries, @index) do %>
          <div class="msg" data-type={row.type} data-status={row.status}>{row.body}</div>
        <% end %>
      </div>
      <details :if={explain?(@agent)} class="chat__debug">
        <summary>output log</summary>
        <p :for={line <- @agent.log}>{line}</p>
      </details>
      <p :if={@error} class="msg" data-type="error">{@error}</p>
      <div class="chat__settings">
        <form id="chat-model" phx-change="chat_model">
          <label for="chat-model-select">Model</label>
          <select id="chat-model-select" name="model" aria-label="Model">
            <option value="" selected={is_nil(@agent.model)}>default</option>
            <option
              :for={model <- Grasp.Agent.models()}
              value={model}
              selected={@agent.model == model}
            >
              {model}
            </option>
          </select>
        </form>
        <form
          id="chat-mode"
          phx-change="chat_mode"
          title="In edit mode the agent may change files under the project and run mix"
        >
          <label for="chat-mode-select">Mode</label>
          <select id="chat-mode-select" name="mode" aria-label="Mode">
            <option value="read" selected={@agent.mode == "read"}>read-only</option>
            <option value="edit" selected={@agent.mode == "edit"}>edit files</option>
          </select>
        </form>
      </div>
      <form id="chat-form" phx-submit="chat_send">
        <input
          type="text"
          name="prompt"
          id="chat-prompt"
          autocomplete="off"
          aria-label="Prompt"
          placeholder="Ask about a flow…"
          phx-update="ignore"
        />
        <button type="submit" disabled={@agent.running?}>Send</button>
        <button :if={@agent.running?} type="button" phx-click="chat_stop">Stop</button>
        <button type="button" phx-click="chat_reset" disabled={@agent.running?}>New</button>
      </form>
    </aside>
    """
  end

  # The rows the log draws, oldest first. An entry with nothing to say — a result that
  # reported no cost — is left out rather than drawn as an empty row with a gap above it.
  # A row's body is one interpolation sitting flush against its tags, since a user's text
  # keeps the line breaks it was typed with (`white-space: pre-wrap`) and any indentation
  # the template put around it would be indentation the reader sees.
  defp rows(entries, index) do
    for entry <- entries, text(entry) != "" do
      %{type: entry.type, status: Map.get(entry, :status), body: body(entry, index)}
    end
  end

  # An assistant turn is Markdown and brings its own block structure; every other row is the
  # text the entry carries.
  defp body(%{type: :assistant} = entry, index),
    do: ChatMarkdown.render(entry.text, known?(index))

  defp body(entry, _index), do: text(entry)

  # Which ids the chat may turn into cards: the ones the index holds, followed through the
  # arities a default argument declares, exactly as a call site on a card resolves them. With
  # no index nothing is linkable, since every button would open a card of nothing.
  defp known?(nil), do: fn _id -> false end
  defp known?(index), do: &match?({:ok, _record}, Grasp.Index.fetch_function(index, &1))

  defp text(%{type: :tool} = entry), do: String.trim("#{entry.name} #{entry.summary}")
  defp text(%{type: :done} = entry), do: done_text(entry)
  defp text(entry), do: entry.text

  defp explain?(agent) do
    agent.log != [] and match?(%{type: :error}, List.last(agent.entries))
  end

  defp done_text(%{cost_usd: cost, turns: turns}) when is_number(cost),
    do: "$#{:erlang.float_to_binary(cost / 1, decimals: 2)} · #{turns} turns"

  defp done_text(_entry), do: ""
end
