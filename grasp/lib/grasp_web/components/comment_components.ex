defmodule GraspWeb.CommentComponents do
  @moduledoc """
  A review thread and the box that writes into it, as the card draws them under a line.

  A thread reads as prose sitting inside a block of code, so it is rendered as a sibling of
  the line it belongs to rather than inside it: the line keeps its monospace, preformatted
  layout and the thread sets its own.

  Resolved threads collapse to a single line. A resolution is a statement that the
  conversation is over, and a card whose every settled argument is still spelled out in full
  buries the code it was written about; the toggle keeps the thread one click away.

  The composer's text is the browser's alone. The textarea is `phx-update="ignore"` so a
  patch arriving mid-sentence cannot rewrite what is being typed, and its id names the
  anchor it was opened at — card, side, line and the thread it replies to — so a draft
  belongs to the one place it was written and never reappears under another line.
  """

  use GraspWeb, :html

  attr :thread, :map, required: true
  attr :card_id, :integer, required: true
  attr :expanded, :boolean, default: false

  attr :aside, :atom,
    doc:
      "why the thread is drawn in the card's footer rather than under a line: `:outdated` " <>
        "when the anchor no longer finds its line, `:hidden` when the view draws no line on " <>
        "its side",
    values: [nil, :outdated, :hidden],
    default: nil

  attr :composing, :map, doc: "the open composer, which may be this thread's reply", default: nil

  @doc """
  One thread: its comments oldest first, the actions that act on it, and the reply box while
  it is open on this thread.
  """
  def thread(assigns) do
    thread = assigns.thread

    entries = [
      %{reply_id: nil, author: thread.author, body: thread.body, created_at: thread.created_at}
      | Enum.map(
          thread.replies,
          &%{reply_id: &1.id, author: &1.author, body: &1.body, created_at: &1.created_at}
        )
    ]

    assigns =
      assign(assigns,
        entries: entries,
        collapsed?: thread.resolved and not assigns.expanded,
        summary: "Resolved · #{count(length(entries))}",
        replying?: is_map(assigns.composing) and assigns.composing.reply_to == thread.id
      )

    ~H"""
    <div
      id={"thread-#{@thread.id}"}
      class={[
        "thread",
        @thread.resolved && "thread--resolved",
        @aside && "thread--outdated"
      ]}
      data-comment-id={@thread.id}
      data-resolved={to_string(@thread.resolved)}
    >
      <p :if={@aside} class="thread__snippet">
        <span class="thread__label">{aside_label(@aside, @thread)}</span>
        <code>{@thread.snippet}</code>
      </p>
      <button
        :if={@collapsed?}
        class="thread__toggle"
        phx-click="toggle_thread"
        phx-value-id={@thread.id}
      >{@summary}</button>
      <%= if not @collapsed? do %>
        <div :for={entry <- @entries} class="comment" data-author={entry.author}>
          <span class="comment__author">{author(entry.author)}</span>
          <time datetime={entry.created_at}>{stamp(entry.created_at)}</time>
          <button
            class="comment__delete"
            phx-click="comment_delete"
            phx-value-id={@thread.id}
            phx-value-reply={entry.reply_id}
            title="Delete"
          >×</button>
          <p class="comment__body">{entry.body}</p>
        </div>
        <div class="thread__actions">
          <button phx-click="comment_reply" phx-value-card={@card_id} phx-value-id={@thread.id}>
            reply
          </button>
          <button
            phx-click="comment_resolve"
            phx-value-id={@thread.id}
            phx-value-resolved={to_string(!@thread.resolved)}
          >
            {if @thread.resolved, do: "reopen", else: "resolve"}
          </button>
          <button :if={@thread.resolved} phx-click="toggle_thread" phx-value-id={@thread.id}>
            hide
          </button>
        </div>
        <.composer :if={@replying?} composing={@composing} card_id={@card_id} />
      <% end %>
    </div>
    """
  end

  attr :composing, :map, required: true
  attr :card_id, :integer, required: true

  @doc """
  The box a comment is written in, carrying the anchor it was opened at as hidden fields so
  the submit says where the comment belongs without the server holding the form's state.
  """
  def composer(assigns) do
    composing = assigns.composing

    id =
      "composer-#{assigns.card_id}-#{composing.side}-#{composing.line}-#{composing.reply_to || "new"}"

    assigns = assign(assigns, id: id, reply?: composing.reply_to != nil)

    ~H"""
    <form id={@id} class="composer" phx-submit="comment_save" phx-hook="Composer">
      <input type="hidden" name="card" value={@card_id} />
      <input type="hidden" name="side" value={@composing.side} />
      <input type="hidden" name="line" value={@composing.line} />
      <input type="hidden" name="reply_to" value={@composing.reply_to} />
      <textarea
        name="body"
        id={"#{@id}-body"}
        rows="3"
        placeholder={if @reply?, do: "Reply…", else: "Leave a comment…"}
        aria-label="Comment"
        phx-update="ignore"
      ></textarea>
      <button type="submit">Comment</button>
      <button type="button" phx-click="comment_cancel">Cancel</button>
    </form>
    """
  end

  # Why a thread sits in the card's footer instead of under a line. A thread the view simply
  # draws no line for — a comment on the base side, in a card reading as source — is still
  # current, and is named for the side it was written on rather than reported as stale.
  defp aside_label(:hidden, thread), do: "Old · L#{thread.line}"
  defp aside_label(:outdated, thread), do: "Outdated · L#{thread.line}"

  # The two writers a thread can hold, named as the reviewer would say them rather than as
  # the store records them.
  defp author("human"), do: "you"
  defp author("agent"), do: "claude"
  defp author(other), do: other

  defp count(1), do: "1 comment"
  defp count(n), do: "#{n} comments"

  # Times are stored as UTC ISO 8601. A stamp the store wrote in another shape is printed as
  # it stands: a comment is worth more than the formatting of its date.
  defp stamp(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%b %-d, %H:%M") <> " UTC"
      {:error, _reason} -> created_at
    end
  end
end
