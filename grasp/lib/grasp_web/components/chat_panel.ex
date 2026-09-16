defmodule GraspWeb.ChatPanel do
  @moduledoc """
  The chat panel: the review agent's transcript, floating over the canvas.

  Everything it draws comes from the agent view the LiveView holds — whether the panel is
  open, the entries, whether a run is live — so a reload or a second tab rejoins the
  conversation mid-run rather than starting from an empty box. The one thing the client owns
  is the text being typed: the prompt carries `phx-update="ignore"` so that a patch landing
  while it is unfocused — one arrives per line of CLI output — cannot reset a half-written
  draft, and the `Chat` hook, not a re-render, clears it after a submit.

  A failed run is the one case where the transcript is not enough: the CLI explains itself
  on stderr, which the runner collects into `log`, so the log is offered beside an error.
  """

  use GraspWeb, :html

  attr :open?, :boolean, required: true
  attr :agent, :map, required: true
  attr :error, :string, default: nil

  def chat_panel(assigns) do
    ~H"""
    <aside id="chat" class="chat" phx-hook="Chat" hidden={!@open?} aria-label="Agent chat">
      <div class="chat__log" id="chat-log" aria-live="polite">
        <%= for entry <- @agent.entries, body(entry) != "" do %>
          <div class="msg" data-type={entry.type} data-status={entry[:status]}>{body(entry)}</div>
        <% end %>
      </div>
      <details :if={explain?(@agent)} class="chat__debug">
        <summary>output log</summary>
        <p :for={line <- @agent.log}>{line}</p>
      </details>
      <p :if={@error} class="msg" data-type="error">{@error}</p>
      <form phx-change="chat_model" class="chat__model">
        <label for="chat-model-select">Model</label>
        <select id="chat-model-select" name="model" aria-label="Model">
          <option value="" selected={is_nil(@agent.model)}>default</option>
          <option :for={model <- Grasp.Agent.models()} value={model} selected={@agent.model == model}>
            {model}
          </option>
        </select>
      </form>
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

  # Assistant text keeps the line breaks the model wrote (`white-space: pre-wrap`), so the
  # body is one interpolation sitting flush against its tags: any indentation the template
  # put around it would be indentation the reader sees. An entry with nothing to say — a
  # result that reported no cost — is skipped rather than drawn as an empty row with a gap
  # above it.
  defp body(%{type: :tool} = entry), do: String.trim("#{entry.name} #{entry.summary}")
  defp body(%{type: :done} = entry), do: done_text(entry)
  defp body(entry), do: entry.text

  defp explain?(agent) do
    agent.log != [] and match?(%{type: :error}, List.last(agent.entries))
  end

  defp done_text(%{cost_usd: cost, turns: turns}) when is_number(cost),
    do: "$#{:erlang.float_to_binary(cost / 1, decimals: 2)} · #{turns} turns"

  defp done_text(_entry), do: ""
end
