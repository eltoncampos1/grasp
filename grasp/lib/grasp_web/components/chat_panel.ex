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
  that opens that function's card. A user's turn is the text they typed. A turn that is
  still being streamed renders the same way, a sentence at a time.

  Tool calls fold: a run of them collapses into one `<details>` labelled with how many
  there were, each row naming in plain words what the agent did and how long it took, open
  while one is still running and closed once they are all finished. A row that failed
  carries the tool's own words under it, which is usually the whole explanation of a turn
  that went nowhere. A turn ends with what it cost and how long it took.

  While a run is live the panel says so twice over: a thinking row wherever the transcript
  has nothing arriving, and a status line carrying the elapsed time and the number of tool
  calls this turn. The elapsed time is the one number the server does not re-render — it
  publishes the millisecond the run started and the `Chat` hook counts from it, so the
  seconds tick without a patch per second.

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
          <%= case row do %>
            <% %{kind: :tools} = group -> %>
              <details class="tools" open={group.open?}>
                <summary>{group.summary}</summary>
                <div :for={tool <- group.tools} class="tool" data-status={tool.status}>
                  <span class="tool__label">{tool.label}</span>
                  <span :if={tool.duration} class="tool__ms">{tool.duration}</span>
                  <pre :if={tool.detail}>{tool.detail}</pre>
                </div>
              </details>
            <% %{kind: :msg} = msg -> %>
              <div class="msg" data-type={msg.type}>{msg.body}</div>
          <% end %>
        <% end %>
        <div :if={thinking?(@agent)} class="msg" data-type="thinking" aria-label="Working">
          <span></span><span></span><span></span>
        </div>
      </div>
      <div :if={@agent.running?} class="chat__status">
        Working · <span data-elapsed-from={@agent.started_at}>0s</span> · {tool_calls(@agent.entries)}
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

  @doc """
  What a tool call reads as in the transcript: what the agent did, in the words a reader
  would use for it.

  `entry` is a `:tool` entry of `Grasp.Agent.Stream`. A tool nothing here names reads as
  its own name and whatever the call was summarised by, so a tool added to the agent
  before it is added here still says something.
  """
  @spec label(map()) :: String.t()
  def label(%{name: name, summary: summary}) do
    case name do
      "search_functions" -> ~s(Searched "#{summary}")
      "get_function" -> "Read #{summary}"
      "get_callers" -> "Callers of #{summary}"
      "get_callees" -> "Callees of #{summary}"
      "find_paths" -> "Traced paths"
      "list_changes" -> "Listed the changes"
      "list_entry_points" -> "Listed entry points"
      "set_cards" -> "Arranged #{summary}"
      "open_card" -> "Opened #{summary}"
      "publish_comments" -> "Published the comments"
      "reload_index" -> "Reloaded the index"
      "Read" -> "Read #{summary}"
      "Grep" -> ~s(Searched files for "#{summary}")
      "Glob" -> "Listed #{summary}"
      "Edit" -> "Edited #{summary}"
      "Write" -> "Wrote #{summary}"
      "Bash" -> "Ran #{summary}"
      other -> String.trim("#{other} #{summary}")
    end
  end

  # The rows the log draws, oldest first: a run of tool entries as one group, everything
  # else as one message each. An entry with nothing to say — a result that reported no cost
  # — is left out rather than drawn as an empty row with a gap above it.
  defp rows(entries, index) do
    entries
    |> Enum.chunk_by(&(&1.type == :tool))
    |> Enum.flat_map(fn
      [%{type: :tool} | _rest] = tools -> [group(tools)]
      others -> Enum.flat_map(others, &message_row(&1, index))
    end)
  end

  defp group(tools) do
    %{
      kind: :tools,
      open?: Enum.any?(tools, &(&1.status == :running)),
      summary: "Used #{count(length(tools), "tool")}",
      tools:
        Enum.map(
          tools,
          &%{
            status: &1.status,
            label: label(&1),
            duration: duration(&1.ms),
            detail: &1.detail
          }
        )
    }
  end

  # A message's body is one interpolation sitting flush against its tags, since a user's
  # text keeps the line breaks it was typed with (`white-space: pre-wrap`) and any
  # indentation the template put around it would be indentation the reader sees.
  defp message_row(entry, index) do
    case text(entry) do
      "" -> []
      _text -> [%{kind: :msg, type: entry.type, body: body(entry, index)}]
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

  defp text(%{type: :done} = entry), do: done_text(entry)
  defp text(entry), do: entry.text

  # The thinking row stands wherever a live run has nothing arriving: the prompt has just
  # gone out, the tools it ran are all finished, or the last thing said is a settled block
  # of text. A partial block is streaming, so the words themselves are the sign of life.
  defp thinking?(%{running?: false}), do: false

  defp thinking?(agent) do
    case List.last(agent.entries) do
      %{type: :user} -> true
      %{type: :tool, status: status} -> status != :running
      %{type: :assistant, partial: partial?} -> not partial?
      _other -> false
    end
  end

  # How much the agent has reached for since the reader last said something.
  defp tool_calls(entries) do
    calls =
      entries
      |> Enum.reverse()
      |> Enum.take_while(&(&1.type != :user))
      |> Enum.count(&(&1.type == :tool))

    count(calls, "tool call")
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp explain?(agent) do
    agent.log != [] and match?(%{type: :error}, List.last(agent.entries))
  end

  defp done_text(entry) do
    [cost(entry.cost_usd), turns(entry.turns), duration(entry.ms)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp cost(usd) when is_number(usd),
    do: "$" <> :erlang.float_to_binary(usd / 1, decimals: 2)

  defp cost(_usd), do: nil

  defp turns(turns) when is_integer(turns), do: count(turns, "turn")
  defp turns(_turns), do: nil

  # Under a second reads in milliseconds, since tenths of a second there are noise; above
  # it reads in seconds, since four digits of milliseconds are a number nobody converts.
  defp duration(ms) when is_integer(ms) and ms < 1_000, do: "#{ms} ms"

  defp duration(ms) when is_integer(ms),
    do: :erlang.float_to_binary(ms / 1_000, decimals: 1) <> " s"

  defp duration(_ms), do: nil
end
