defmodule GraspWeb.ChatPanel do
  @moduledoc """
  The chat panel: the review agent's transcript, floating over the canvas.

  Everything it draws comes from the agent view the LiveView holds — whether the panel is
  open, the entries, whether a run is live — so a reload or a second tab rejoins the
  conversation mid-run rather than starting from an empty box. The only thing the client
  owns is the text being typed, which is why the input is uncontrolled and the `Chat` hook,
  not a re-render, clears it after a submit.

  A failed run is the one case where the transcript is not enough: the CLI explains itself
  on stderr, which the runner collects into `log`, so the log is offered beside an error.
  """

  use GraspWeb, :html

  attr :open?, :boolean, required: true
  attr :agent, :map, required: true
  attr :error, :string, default: nil

  def chat_panel(assigns) do
    ~H"""
    <aside id="chat" class="chat" phx-hook="Chat" hidden={!@open?}>
      <div class="chat__log" id="chat-log">
        <%= for entry <- @agent.entries do %>
          <div class="msg" data-type={entry.type} data-status={entry[:status]}>{body(entry)}</div>
        <% end %>
      </div>
      <details :if={explain?(@agent)} class="chat__debug">
        <summary>output log</summary>
        <p :for={line <- @agent.log}>{line}</p>
      </details>
      <p :if={@error} class="msg" data-type="error">{@error}</p>
      <form phx-submit="chat_send">
        <input
          type="text"
          name="prompt"
          id="chat-prompt"
          autocomplete="off"
          placeholder="Ask about a flow…"
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
  # put around it would be indentation the reader sees.
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
