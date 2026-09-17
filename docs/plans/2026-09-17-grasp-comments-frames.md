# Grasp Review Comments, Following Frames and Far-Zoom Retune Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) A group's frame is drawn round where its cards actually are, so a dragged card never leaks out of it, and dropping a card anywhere inside a frame's area joins the group. (2) The far-zoom view triggers at a farther zoom and uses a much smaller label. (3) Reviewers comment on lines of a card as on a GitHub pull request; the agent lists, answers and resolves those comments over MCP, and an opt-in edit mode lets it act on them ("address all the comments and update the diagram afterwards").

**Architecture:** Frames become a hook-drawn overlay under the cards (union of the section's card boxes, padded), the section header is translated to the frame's corner, and the drop test reads the same rectangles. Comments live in a new project-level GenServer `Grasp.Comments` persisted to `<root>/.grasp/comments.json`, anchored to `{function_id, side, line}` with a text snippet that re-anchors at render time (`Grasp.Comments.Anchor`). `Grasp.Highlight` gains a per-line API so the card body can interleave threads and a composer between lines. Four MCP tools expose the threads; `Grasp.Agent` gains a `read | edit` mode that changes the CLI's tool allowlist and system prompt.

**Tech Stack:** Elixir 1.19 / Phoenix LiveView 1.2, anubis_mcp 2.0, hook JS (esbuild), CSS custom properties.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — §Layout (frames, semantic zoom), §Comments, §Known gaps (milestone 5.4), Part 3 (comment tools), §Chat panel (edit mode).

## Global Constraints

- Public repo: no real company, product or private project names anywhere (code, tests, docs, commits); fixtures are `SampleApp`.
- Every module has a `@moduledoc`; every public function `@doc` + `@spec`; HEEx components document with `attr`/`slot` and carry no `@spec`. Comments state durable facts, never history ("was", "now", "previously", "per review" are forbidden).
- UI state is server-owned unless it must be the browser's (a draft in a textarea, the canvas view). Anything the hook sets on a server-rendered element is re-applied in `updated()`.
- CSS through the tokens in `app.css` (`--fg-muted`, `--border`, `--accent-soft`, `--space-*`, `--radius`, `--zoom`, `--far-size`); no hard-coded colours.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test` (327 today). No test is deleted without a replacement covering the same behaviour. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The implementer never dispatches subagents and never starts a long-running server (`mix grasp.serve`); the user runs the viewer.

---

### Task 1: Frames follow their cards; drop by area; far-zoom retune

**Files:** modify `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`, `grasp/lib/grasp_web/live/review_live.ex` (stage markup), README §Gestures; tests `grasp/test/grasp_web/live/review_live_test.exs`.

**Requirements:**

- **Far zoom.** `FAR_SCALE` 0.6 → `0.5` in `canvas.js`; `--far-size: 14px` → `10px` in `app.css`. Update the comments that quote them and the README if it names either number.
- **Frame layer.** Inside `#stage`, before the `#connectors` svg, render `<div id="frames" class="frames" phx-update="ignore" aria-hidden="true"></div>`. CSS: `.frames { position: absolute; inset: 0; z-index: 0; pointer-events: none; }` and `.frame { position: absolute; border: calc(1px / var(--zoom, 1)) solid var(--border); border-radius: var(--radius); background: color-mix(in srgb, var(--bg-raised) 60%, transparent); }`. `.flow[data-grouped]` loses its `border`, `border-radius` and `background` but keeps its padding (the auto layout still leaves room between sections). `.flows` keeps `z-index: 1`.
- **Drawing.** In the hook, add `drawFrames()` and a `draw()` that calls `drawFrames()` then `drawConnectors()`; every call site of `drawConnectors()` (mounted, updated, the ResizeObserver, the far flip in `applyView`, `pointerMove` during a card drag, `pointerCancel`) calls `draw()` instead. `drawFrames()`:
  - Looks up the layer each time it is not connected (`this.frameLayer?.isConnected`), as `drawConnectors` does with `#edges`.
  - For every `.flow[data-grouped]` in the canvas: collect the `getBoundingClientRect()` of its `.card`s with a non-zero box; skip the section (drawing no frame, clearing the header's translate) when there are none. Convert to stage coordinates as `stageBox` does: `(b.left - s.left) / scale`, etc., with `s` the stage's rect and `scale = this.view.scale`.
  - Header: the section's `.flow__title`. Its natural position is its current rect minus the translate the hook last gave it — parse `title.style.translate` (`"Xpx Ypx"`, `""` → 0 0, a single value → y 0). Set `title.style.translate` so the header's top-left lands at `(box.left, box.top - (titleHeight + FRAME_TITLE_GAP))`, `FRAME_TITLE_GAP = 8` (matching `--space-s`, so a section nobody dragged gets a translate of 0). Everything in stage units.
  - The frame rectangle is the card union padded by `FRAME_PAD = 16` on the left, right and bottom, and by `titleHeight + FRAME_TITLE_GAP + FRAME_PAD` on the top (just `FRAME_PAD` when the section has no header). Push `{group: Number(flow.dataset.group), left, top, right, bottom}` to `this.frames` and render `<div class="frame" data-group="G" style="left:..px;top:..px;width:..px;height:..px"></div>` into the layer's `innerHTML` (one write per draw, like the edges).
  - The drag path already sets the dragged node's inline translate before calling the draw, so the frame follows the card live.
- **Drop by area.** Replace `groupUnder(e, drag)`: pointer to stage coordinates; `own = Number(drag.node.closest(".flow")?.dataset.group)` (NaN for the ungrouped section); candidates are `this.frames` entries whose rectangle (padding included) contains the point and whose `group !== own`; answer the last candidate's group, or `null`. Remove the `elementFromPoint`/`pointerEvents` dance and update the comment above the function and the hook's file comment. Server-side `move_card` is unchanged.
- **Fit.** `fitOnce()` measures `.card, .frame` so a fit shows the frames' padding and headers too.
- **Tests (LiveView, `review_live_test.exs`):** the stage renders `#frames[phx-update="ignore"]` before `#connectors`; a grouped section renders with `data-group` equal to its group id and no longer depends on a CSS frame (assert `#flow-N[data-grouped][data-group="N"]` and `#flow-N .flow__title`). Frame geometry is browser work and is not unit-tested; say so in the report.
- Gates; commit `Frames follow their cards and take a drop anywhere inside them`.

---

### Task 2: The comments store and anchoring

**Files:** create `grasp/lib/grasp/comments.ex`, `grasp/lib/grasp/comments/anchor.ex`, `grasp/test/grasp/comments_test.exs`, `grasp/test/grasp/comments/anchor_test.exs`; modify `grasp/lib/grasp/application.ex`, `grasp/config/config.exs` (`comments_path: nil`), `grasp/config/test.exs`.

**Interfaces (produced):**

```elixir
defmodule Grasp.Comments do
  @type author :: String.t()            # "human" | "agent"
  @type side :: String.t()              # "new" | "old"
  @type reply :: %{id: pos_integer(), author: author(), body: String.t(), created_at: String.t()}
  @type thread :: %{
          id: pos_integer(), function_id: String.t(), side: side(), line: pos_integer(),
          snippet: String.t() | nil, body: String.t(), author: author(), created_at: String.t(),
          resolved: boolean(), replies: [reply()]
        }
  @spec start_link(keyword()) :: GenServer.on_start()      # name: __MODULE__; opts[:path] overrides the file
  @spec subscribe() :: :ok | {:error, term()}               # :comments_changed on topic "comments"
  @spec list(keyword()) :: [thread()]                       # function_id: id, include_resolved: bool (default false); sorted by id
  @spec by_function() :: %{String.t() => [thread()]}        # every thread, resolved included, sorted by id per function
  @spec fetch(pos_integer()) :: {:ok, thread()} | :error
  @spec add(map()) :: {:ok, thread()} | {:error, :invalid}  # %{function_id, side, line, body, author, snippet}
  @spec reply(pos_integer(), map()) :: {:ok, thread()} | {:error, :unknown | :invalid}   # %{body, author}
  @spec set_resolved(pos_integer(), boolean()) :: {:ok, thread()} | {:error, :unknown}
  @spec delete(pos_integer()) :: :ok                        # unknown id is a no-op
  @spec delete_reply(pos_integer(), pos_integer()) :: :ok
  @spec path() :: String.t() | nil                          # the file written, nil when memory-only
  @spec snippet(map() | nil, side(), pos_integer()) :: String.t() | nil   # trimmed text of that line of the record, nil out of range / no record
end

defmodule Grasp.Comments.Anchor do
  @type placement :: {:new, pos_integer()} | {:old, pos_integer()} | :outdated | :orphan
  @spec place(Grasp.Comments.thread(), map() | nil) :: placement()
end
```

**Requirements:**

- **Validation in `add/1` and `reply/2`:** `function_id` a binary, `side` in `~w(new old)`, `line` a positive integer, `author` in `~w(human agent)`, `body` a binary whose trim is non-empty (stored trimmed); anything else → `{:error, :invalid}`. `snippet` is stored as given (nil allowed). `created_at` = `DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()`. Thread ids and reply ids come from one `next_id` counter, never reused.
- **Persistence.** File: `opts[:path]` → else `Application.get_env(:grasp, :comments_path)` → else `Path.join(root, ".grasp/comments.json")` when `Grasp.IndexStore.get()` gives a `project["root"]` that `File.dir?/1` → else nil (memory only). On init, read the file if it exists: `%{"version" => 1, "next_id" => n, "comments" => [...]}` with string keys converted to the atom-keyed thread shape; a missing file starts empty; an unreadable or malformed file logs one `Logger.warning` and starts empty. After every mutation, `File.mkdir_p!` the directory and write the document with `Jason.encode!(doc, pretty: true)`; a write failure logs a warning and keeps the in-memory state. The store subscribes to `Grasp.IndexStore` reloads; on `:index_reloaded`, if the derived path (with no `opts[:path]`/config override) changes, load that file instead. Broadcast `:comments_changed` after every successful mutation (also after `delete` of an unknown id? no — only when something changed).
- **`snippet/3`:** side `"new"`: split `record["source"]` on `"\n"`, numbered from `record["span"]["start_line"]`; side `"old"`: split `record["base_source"]`, numbered from 1; return `String.trim(text)` of that line or nil when out of range, the record is nil, or the side's source is nil.
- **`Anchor.place/2`:** record nil → `:orphan`. Side `"new"`: the numbered current lines as above; if `thread.line` is in range and (`snippet` is nil or the line's trimmed text equals `snippet`) → `{:new, line}`; else if `snippet` is a non-empty binary and exactly one current line's trimmed text equals it → `{:new, that line}`; else `:outdated`. Side `"old"`: the same over `base_source` numbered from 1, answering `{:old, n}`; a record without `base_source` → `:outdated`.
- **Supervision & config.** Add `{Grasp.Comments, []}` to `Grasp.Application` right after `Grasp.IndexStore`. `config.exs`: `config :grasp, ..., comments_path: nil`. `test.exs`: `config :grasp, comments_path: Path.join(System.tmp_dir!(), "grasp-test-#{System.os_time(:millisecond)}/comments.json")` — one temporary file per test run so the fixture project is never written to.
- **Tests.** The API is global (one store per viewer), so `comments_test.exs` tests through the application's store with unique function ids (`"Test.Fn#{System.unique_integer([:positive])}.run/0"`) and unique bodies, and never asserts on totals. Persistence is tested through two pure `@doc false` functions: `encode(threads, next_id) :: String.t()` (the JSON document written) and `decode(String.t()) :: {:ok, {threads, next_id}} | {:error, term()}`, round-tripped in the test; the GenServer uses them for its reads and writes. Cover: add/reply/resolve/delete/delete_reply/list filters/by_function ordering; validation errors; the pure round-trip; `snippet/3` on the fixture `SampleApp.Formatter.shout/1` (new side, its span, and old side line 1 of `base_source`); a broadcast received after `add`. `anchor_test.exs`: anchored on its own line; moved (snippet found once elsewhere) → the new line; edited (no match) → `:outdated`; duplicate snippet elsewhere but own line intact → own line; duplicate snippet and own line changed → `:outdated`; old side against `base_source`; nil record → `:orphan`.
- Gates; commit `Review comments: a project-level store with text-anchored placement`.

---

### Task 3: Per-line rendering with a comment gutter

**Files:** modify `grasp/lib/grasp/highlight.ex`, `grasp/lib/grasp_web/components/card_components.ex` (body markup only), `grasp/assets/css/app.css`; tests `grasp/test/grasp/highlight_test.exs`, `grasp/test/grasp/diff_test.exs` if it asserts markup, `grasp/test/grasp_web/components/card_components_test.exs`.

**Interfaces (produced):**

```elixir
@type line :: %{side: :new | :old, line: pos_integer(), html: String.t()}
@spec lines(map(), opts()) :: [line()]        # what render/2 joins
@spec diff_lines(map(), opts()) :: [line()]   # what render_diff/2 joins; a deleted line is side :old, line = its base line
# render/2 and render_diff/2 keep their signatures and return {:safe, Enum.map_join(lines, "", & &1.html)}
```

**Requirements:**

- Every line's gutter span becomes the comment control: `<span class="ln" role="button" title="Comment on this line" phx-click="comment_start" phx-value-card="ID" phx-value-side="new|old" phx-value-line="N">N</span>`. For a deleted line in the diff (`side :old`) the visible number stays empty as today, `phx-value-line` is the base line, and the line element carries `data-base-line="N"`. `data-line` on current lines is unchanged.
- `body_builder/2` and the diff reducer are refactored so `lines/2` / `diff_lines/2` return the list and `render/2` / `render_diff/2` join it. Moduledoc: describe the list API and the gutter control; drop nothing else.
- Card body: `<pre class="card__body lumis">{@body}</pre>` becomes `<div class="card__body lumis">` whose children are the lines (this task renders them by joining, exactly as before — Task 4 interleaves threads). CSS: `.card .card__body` keeps its rules (they were written for the `pre`; confirm `margin`, `padding`, `overflow-x`, `line-height` still apply and that `.line { display: block; white-space: pre }` carries the whitespace). Gutter affordance: `.ln { cursor: pointer; }` and `.line:hover .ln::after { content: "+"; ... }` positioned so it does not shift the text (an absolutely positioned pseudo-element inside a `position: relative` `.ln`, or a fixed-width gutter with the `+` over the number's left margin — pick one and keep the gutter width stable), colour `var(--accent)`.
- **Tests.** `highlight_test.exs`: `lines/2` on the fixture `SampleApp.Greeter.greet/2` gives one entry per source line with `side: :new` and consecutive line numbers from the span; each `html` contains the `phx-click="comment_start"` gutter with matching `phx-value-line`; `render/2` equals the join. `diff_lines/2` on `SampleApp.Formatter.shout/1` has an `:old` entry for the deleted base line carrying `data-base-line` and `phx-value-side="old"`. Card components test: the body is a `div.card__body` and the `pre` is gone.
- Gates; commit `Lines are rendered one at a time, each with a comment gutter`.

---

### Task 4: Threads and the composer on the card

**Files:** create `grasp/lib/grasp_web/components/comment_components.ex`, `grasp/assets/js/hooks/composer.js`; modify `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/js/app.js` (register `Composer`), `grasp/assets/css/app.css`, README §Gestures; tests `grasp/test/grasp_web/live/review_live_test.exs` (or a new `comments_live_test.exs`).

**Interfaces (consumed):** Task 2's `Grasp.Comments` and `Anchor.place/2`; Task 3's `Grasp.Highlight.lines/2` / `diff_lines/2` and the `comment_start` gutter event.

**Requirements:**

- **LiveView state.** On mount: `Grasp.Comments.subscribe()` when connected; assigns `comments: Grasp.Comments.by_function()`, `composing: nil`, `expanded_threads: MapSet.new()`. `handle_info(:comments_changed, socket)` re-reads `by_function/0`. Pass `comments={@comments}`, `composing={@composing}` and `expanded_threads={@expanded_threads}` down to `card_node` → `card`.
- **Events** (all guarded on well-formed params; garbage is a no-op like the others): `comment_start` (`card`, `side`, `line`) → `composing: %{card: id, side: side, line: line, reply_to: nil}` after `close_overlays/1`; `comment_reply` (`card`, `id`) → `composing` with `reply_to: thread id` and the thread's side/line; `comment_cancel` → `composing: nil`; `comment_save` (form: `body`, hidden `card`, `side`, `line`, `reply_to`) → blank body is a no-op that keeps the composer; otherwise a reply calls `Grasp.Comments.reply(reply_to, %{body: body, author: "human"})`, a new thread calls `Grasp.Comments.add(%{function_id: the card's function_id, side: side, line: line, body: body, author: "human", snippet: Grasp.Comments.snippet(record, side, line)})`; then `composing: nil`. `comment_resolve` (`id`, `resolved` "true"/"false") → `set_resolved`. `comment_delete` (`id`, optional `reply`) → `delete_reply/2` or `delete/1`. `toggle_thread` (`id`) toggles membership in `expanded_threads`. `close_overlays/1` also clears `composing`, so opening the callers menu or a rename closes the composer (and vice versa).
- **Card body.** In `function_card/1`: `lines = if view == :diff, do: Highlight.diff_lines(record, opts), else: Highlight.lines(record, opts)`; `threads = Map.get(comments, record["id"], [])`; placements = `Enum.group_by(threads, &Anchor.place(&1, record))`; anchored threads keyed `{:new, n}` / `{:old, n}`, outdated under `:outdated`. Render:
  ```heex
  <div class="card__body lumis"><%= for line <- @lines do %>{raw(line.html)}<.thread :for={thread <- Map.get(@placed, {line.side, line.line}, [])} thread={thread} card_id={@card.id} expanded={MapSet.member?(@expanded_threads, thread.id)} composing={@composing} /><.composer :if={composing_at?(@composing, @card.id, line.side, line.line)} composing={@composing} card_id={@card.id} /><% end %></div>
  <footer :if={@outdated != []} class="card__outdated"><.thread :for={thread <- @outdated} ... outdated /></footer>
  ```
  (whitespace between children of the `div` is normal white-space and does not render; do not reintroduce a `pre`). A stub card renders no threads.
- **`GraspWeb.CommentComponents`** (`use GraspWeb, :html`; `attr`s documented):
  - `thread/1`: `<div id={"thread-#{id}"} class={["thread", resolved && "thread--resolved", outdated && "thread--outdated"]} data-comment-id data-resolved>`. Outdated: a first row `<p class="thread__snippet">` quoting `snippet` with the label `Outdated · L{line}`. Resolved and not expanded: one `<button class="thread__toggle" phx-click="toggle_thread" phx-value-id>Resolved · {n} comment(s)</button>` and nothing else. Otherwise each comment (root then replies) as `<div class="comment" data-author={author}>` with `<span class="comment__author">{you | claude}</span>`, `<time datetime={created_at}>{Calendar.strftime(dt, "%b %-d, %H:%M")} UTC</time>`, `<button class="comment__delete" phx-click="comment_delete" phx-value-id={thread.id} phx-value-reply={reply.id or absent} title="Delete">×</button>`, `<p class="comment__body">{body}</p>` (CSS `white-space: pre-wrap`); then `<div class="thread__actions">` with `reply` (`comment_reply`, `phx-value-card`, `phx-value-id`), `resolve`/`reopen` (`comment_resolve`, `phx-value-resolved`), and for an expanded resolved thread `hide` (`toggle_thread`). Author labels: `"human"` → `you`, `"agent"` → `claude`. The reply composer renders inside the thread after the actions when `composing.reply_to == thread.id`.
  - `composer/1`: `<form id={"composer-#{card_id}-#{side}-#{line}-#{reply_to || "new"}"} class="composer" phx-submit="comment_save" phx-hook="Composer">` with hidden `card`, `side`, `line`, `reply_to` inputs, `<textarea name="body" id={"#{form id}-body"} rows="3" placeholder={reply? && "Reply…" || "Leave a comment…"} aria-label="Comment" phx-update="ignore"></textarea>`, `<button type="submit">Comment</button> <button type="button" phx-click="comment_cancel">Cancel</button>`. A distinct id per anchor is what lets `phx-update="ignore"` keep a draft without carrying it to another line.
- **`composer.js`** (`Composer` hook): `mounted()` focuses the textarea; `keydown` on the form: `(metaKey || ctrlKey) && key === "Enter"` → `preventDefault(); this.el.requestSubmit()`; `Escape` → `preventDefault(); this.pushEvent("comment_cancel", {})`. Nothing else; the draft is the browser's. Register in `app.js`. `keys.js` already ignores chords typed in a `TEXTAREA`, so no change there; `canvas.js`'s `pointerDown` already refuses to pan or drag from inside a card body — verify a press on the textarea does neither (the `.card` guard covers it) and that `wheel` over the textarea scrolls it (`scrollableUnder`).
- **CSS.** `.thread`, `.thread--outdated`, `.comment`, `.comment__author` (badge-like, `data-author="agent"` tinted `--accent-soft`), `.comment__body`, `.thread__actions` buttons muted, `.composer` (block, `padding: var(--space-s) var(--space-m)`, textarea `font: inherit; font-family: var(--sans); width: 100%`), `.card__outdated`; `user-select: text; cursor: auto` inside threads; `body.grasp-far #stage .thread, body.grasp-far #stage .composer, body.grasp-far #stage .card__outdated { display: none; }`. Thread and composer are `font-family: var(--sans); font-size: 13px; white-space: normal` so they do not inherit the code's `pre`.
- **Tests (LiveView).** Open `SampleApp.Greeter.greet/2` as a root; click its first line's gutter (`#card-1 .line[data-line="N"] .ln`) → `#card-1 form.composer` exists with hidden `line=N`; submit `comment_save` with a unique body → `#card-1 .thread .comment[data-author="human"]` under `.line[data-line="N"]` (assert the thread element follows that line in the rendered HTML, e.g. by `render(view)` index comparison or `has_element?` on `.line[data-line=N] + .thread`) and the composer is gone; `comment_reply` + save → two `.comment`s; `comment_resolve` → collapsed `thread__toggle` text `Resolved · 2 comments`; `toggle_thread` expands; `comment_delete` of the reply → one comment; `comment_delete` of the thread → gone; a blank save keeps the composer; a comment stored on a line whose snippet no longer matches (use `Grasp.Comments.add/1` directly with a bogus snippet and a line in range) renders in `footer.card__outdated`; a second LiveView on another session name sees the thread (project-level). Diff view: on `SampleApp.Formatter.shout/1` in diff view, click the deleted line's gutter (`.line[data-op="del"] .ln`) → composer with `side=old`; save → thread rendered after that `del` line.
- README §Gestures: add "Click a line number to comment; ⌘/Ctrl+Enter saves, Escape cancels; reply, resolve, delete on the thread."
- Gates; commit `Comment on a line of a card, reply, resolve and delete`.

---

### Task 5: The Comments sidebar group

**Files:** modify `grasp/lib/grasp_web/components/sidebar.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/css/app.css`; tests `grasp/test/grasp_web/components/sidebar_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`.

**Requirements:**

- `group_kinds/0` gains `"comments"` (first). `default_expanded/2` — new arity `default_expanded(index, open_thread_count)`; keep `default_expanded/1` delegating with 0 — adds `"comments"` when the count is positive. `ReviewLive` computes the count from `Grasp.Comments.list()` at mount and on `:index_reloaded` (not on `:comments_changed`).
- `entry_groups/1` gains `attr :comments, :map, required: true` (the `by_function/0` map) and renders, first, `<section class="group" data-kind="comments">` when any thread is open, titled `Comments` with the open count, rows grouped by module (module parsed from the function id as `module_of/1` does; unknown → `nil` heading skipped): `<button class="entry entry--comment" phx-click="open_comment" phx-value-id={thread.id} title={function_id}>` containing `<span class="entry__where">{name}/{arity} · L{line}</span><span class="entry__excerpt">{first 60 characters of body, ellipsised}</span>`. Threads whose function is not in the index render with class `entry--orphan` (muted) and still open nothing but focus nothing — clicking is a no-op the handler ignores.
- Event `open_comment` (`id`): fetch the thread; if its function is in the index, `Session.open_root(name, function_id)`, find the card (`Forest.find/2`), and when `Anchor.place/2` gives `{:new, n}` set `Session.set_highlight(name, card_id, %{"lines" => [n, n]})`; `{:old, _}` or `:outdated` → focus only; clear the selection like the other openers.
- CSS: `.entry--comment { display: flex; flex-direction: column; align-items: start; }`, `.entry__excerpt { color: var(--fg-muted); font-family: var(--sans); font-size: 12px; }`, `.entry--orphan { color: var(--fg-faint); }`.
- **Tests.** Sidebar component: with one open thread on `SampleApp.Greeter.greet/2` the group renders first with count 1 and the row text `greet/2 · L{line}`; resolved-only → no group; `default_expanded(index, 1)` contains `"comments"`, `default_expanded(index, 0)` does not. LiveView: `open_comment` opens the card and gives it `data-highlight-key="lines:N-N"`.
- Gates; commit `The sidebar lists open comments and jumps to their lines`.

---

### Task 6: Comment tools over MCP

**Files:** create `grasp/lib/grasp/mcp/tools/{list_comments,add_comment,reply_comment,resolve_comment}.ex`, `grasp/lib/grasp/mcp/comments.ex` (pure shaping); modify `grasp/lib/grasp/mcp/server.ex`, `grasp/lib/grasp/mcp/tools/get_function.ex`, README §MCP; tests `grasp/test/grasp/mcp/comment_tools_test.exs`, `grasp/test/grasp_web/mcp_test.exs` (tool name list).

**Interfaces (consumed):** Task 2.

**Requirements:**

- `Grasp.MCP.Comments.thread_map(thread, index) :: map()` — the thread's fields with string keys plus `"file"` (the record's, or nil), `"status"` (`"anchored" | "outdated" | "orphan"` from `Anchor.place/2`) and `"anchored_line"` (the placed line, nil otherwise). `Grasp.MCP.Comments.check_line(record, side, line) :: :ok | {:error, message}` — `"new"`: within `span.start_line..span.end_line`; `"old"`: `base_source` present and `1..line count`; the message names the function and the range (`"line 99 is outside SampleApp.Greeter.greet/2 (lines 4..9)"`).
- Tools (moduledocs are the descriptions agents read — say when to use each):
  - `list_comments`: `function_id` (optional string), `include_resolved` (optional boolean, default false) → `%{"total" => n, "comments" => [thread_map]}` sorted by id. Works without an index? No — needs the index for status; reply the standard no-index error.
  - `add_comment`: `function_id` (required), `line` (required integer), `body` (required), `side` (optional, `"new"` default; anything but `new`/`old` is an error) → resolves the function (`Tools.fetch_function/2`, canonical id), `check_line`, snippet from `Grasp.Comments.snippet/3`, `Grasp.Comments.add/1` with `author: "agent"` → the thread map. `{:error, :invalid}` → tool error `"body must not be blank"`.
  - `reply_comment`: `comment_id` (required integer), `body` → `reply/2` as `"agent"`; unknown → `"unknown comment: N"`.
  - `resolve_comment`: `comment_id`, `resolved` (optional boolean, default true) → `set_resolved/2` → thread map.
- `get_function` adds `"comments"` → the function's open threads as thread maps.
- Register the four components; update the sorted name list in `mcp_test.exs`. README §MCP: a short "Comments" subsection listing the four tools and the `comments` key on `get_function`.
- **Tests** (direct `execute/2` like `session_tools_test.exs`, unique bodies): add → list shows it with `status: "anchored"` and `anchored_line`; add on a line out of range → error naming the span; add with a blank body → error; reply → replies length 1 with `author: "agent"`; resolve → excluded from `list_comments` unless `include_resolved`; reopen; unknown id errors; `get_function` carries the open thread; `list_comments` on an unknown `function_id` filter → empty, no error.
- Gates; commit `Comments over MCP: list, add, reply, resolve`.

---

### Task 7: The agent's edit mode and comment-aware prompt

**Files:** modify `grasp/lib/grasp/agent.ex`, `grasp/lib/grasp/agent/runner.ex`, `grasp/lib/grasp/agent/command.ex`, `grasp/lib/grasp_web/components/chat_panel.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/css/app.css` (if needed), README §Ask the agent; tests `grasp/test/grasp/agent/command_test.exs`, `grasp/test/grasp/agent/runner_test.exs`, `grasp/test/grasp_web/live/chat_test.exs`.

**Interfaces (produced):**

```elixir
Grasp.Agent.modes() :: ["read", "edit"]
Grasp.Agent.set_mode(name, "read" | "edit") :: :ok | {:error, :unknown_mode}
view gains mode: "read" | "edit"                       # default "read"
Grasp.Agent.Command.build(prompt, opts) — opts gain {:mode, "read" | "edit"} (default "read")
                                        and {:reindex, String.t()} (the command the prompt spells out)
Grasp.Agent.Command.system_prompt(session, mode, reindex) :: String.t()   # replaces system_prompt/1 (update callers/tests)
Grasp.Agent.Command.reindex_command(Grasp.Index.t() | nil, watched_path :: String.t() | nil) :: String.t()
```

**Requirements:**

- **Tools by mode.** `read`: `--tools Read,Grep,Glob` and `--allowedTools mcp__grasp,Read,Grep,Glob` (unchanged). `edit`: `--tools Read,Grep,Glob,Edit,Write,Bash` and `--allowedTools mcp__grasp,Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(git status:*),Bash(git diff:*)`. Module attributes for both; moduledoc updated (it currently says the allowlist "keeps the agent to reading").
- **`reindex_command/2`:** `"mix grasp.index"` + `" --base #{base_ref}"` when `index.git["base_ref"]` is a binary + `" --out #{relative}"` when `watched_path` is not `Path.join(root, ".grasp/index.json")` (relative to the root when under it, else absolute). nil index → `"mix grasp.index"`. The runner passes `Grasp.IndexStore.get()` and `Grasp.IndexStore.path()`.
- **System prompt.** Keep the current three steps; replace the closing line and add, in both modes, a paragraph on comments: reviewers leave comments on lines of the cards like review comments on a pull request; `list_comments` returns the open ones with the function, the line and its text, the body and the replies; when asked to address, answer or handle comments, read each one (`get_function`, `Read`), act on it, then `reply_comment` with one or two sentences on what was done and `resolve_comment`; `add_comment` leaves a remark of the agent's own on a line worth attention. `read` mode closes with: "Do not edit files or run commands — this chat is in read mode. When a comment asks for a code change, reply with the change you would make and tell the user to switch the chat to edit mode." `edit` mode closes with: "You may edit files under the project root and run mix. After editing: run `mix format` on the files you touched; rebuild the index from the project root with `<reindex>` — the viewer reloads the cards from it within a couple of seconds; then arrange the cards again (set_cards or highlight_card) so the diagram shows the code as it now is. Keep every change to what the comments ask for, and say what you changed." Update the `runner_test`/`command_test` assertions that read the prompt.
- **Runner.** State gains `mode: "read"`; `handle_call({:set_mode, mode})` like `set_model`; `view/1` carries `mode`; `Command.build` receives `mode:` and `reindex:`. `Grasp.Agent.set_mode/2` validates against `modes/0`. `reset/1` keeps the mode (like the model).
- **Chat panel.** Beside the model select, a second form `#chat-mode` (`phx-change="chat_mode"`) with `<select id="chat-mode-select" name="mode" aria-label="Mode">` options `read-only` (`read`) and `edit files` (`edit`), selected from `@agent.mode`; `title="In edit mode the agent may change files under the project and run mix"`. Event `chat_mode` → `Grasp.Agent.set_mode`; unknown ignored. Both selects sit in one `.chat__model` row (rename the class to `.chat__settings` if clearer; keep the ids the tests use).
- README §Ask the agent: the mode, what edit mode allows, the comments workflow ("address all the comments and update the diagram") and the one-line safety note.
- **Tests.** `command_test`: edit mode argv carries the edit tool lists and the prompt contains `mix grasp.index --base main` for the fixture (its git block has `base_ref` `main`) and the "read mode" sentence in read mode; `reindex_command/2` with a non-default out path. `runner_test`: `set_mode("edit")` shows in the view, `set_mode("bogus")` is `{:error, :unknown_mode}`, the fake CLI's echoed argv contains `Bash(mix:*)` after `set_mode("edit")`. `chat_test`: the select renders and `chat_mode` changes `@agent.mode`.
- Gates; commit `The agent has an edit mode and knows about review comments`.

---

### Task 8: Docs sweep

**Files:** `README.md`, `docs/specs/2026-09-15-grasp-design.md` (only if a task changed a name the spec quotes), `grasp/lib/mix/tasks/grasp.serve.ex` moduledoc (mention `.grasp/comments.json` beside the index).

**Requirements:** Read the README top to bottom against what Tasks 1–7 shipped: §Gestures (frames follow cards; drop anywhere in a frame; click a line number to comment; keys), §PR mode (commenting on a deleted line), §MCP (the four tools, `comments` on `get_function`), §Ask the agent (mode select, the address-the-comments prompt, `.grasp/comments.json` travels with the checkout — suggest committing or ignoring it). Fix anything stale (`0.6`, `14px`). No new features. Gates (docs only: `mix format --check-formatted` still runs); commit `Document comments, edit mode and following frames`.

---

### Task 9: A card opened from inside a frame joins the frame

**Files:** modify `grasp/lib/grasp/session/forest.ex`, `docs/specs/2026-09-15-grasp-design.md` §Card graph (one sentence), README §Gestures (one clause); tests `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`.

**Requirements:**

- `Forest.open_caller/4` and `Forest.open_child/4`: when the card they create is **new** (no card showed the function yet), it takes the `group` of the card it was opened from — the callee for `open_caller`, the parent for `open_child` — so it is laid out in that card's section: a caller lands one column to the left of the callee inside the same frame, a callee one column to the right. A card that already exists keeps the group it has (an edge is added, nothing moves). Opening from an ungrouped card is unchanged (`group: nil`). `open_root/2` is unchanged.
- Implement in `add_card/2`'s callers, not by a post-hoc `regroup`: the new card is created with the group set. Update the moduledoc's Groups paragraph ("a card opened from a member of a group joins the group") and the `@doc` of both functions.
- **Tests (forest):** open A as root, group it (`new_group`), `open_caller` B from A → B's `group == A's group`, and `sections/1` shows one section with columns `[[B], [A]]`; `open_child` C from A → C in the group, columns `[[B], [A], [C]]`; opening a caller that is already on screen in another group leaves its group as it was; `open_caller` from an ungrouped card gives `group: nil`. **LiveView:** a card in a frame → `open_caller` (click the caller in the callers menu) → the new card renders inside `#flow-N` for that group.
- Gates; commit `A card opened from a frame joins the frame`.
