# Grasp Ranged Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A review comment can cover a range of lines: drag along a card's line numbers (or Shift-click a second one while composing) to select the range, the thread renders under its last line with the range tinted, agents can create and read ranged threads over MCP, and publishing posts them to GitHub as multi-line review comments.

**Architecture:** `Grasp.Comments` threads gain `end_line` (`nil` or the last line of the range on the same side, `> line`); the snippet stays the first line's text so `Grasp.Comments.Anchor` is unchanged. The LiveView's `composing` gains `end_line`; `comment_start` accepts it; a `Gutter` JS hook on the card body turns a pointer drag across `.ln` elements into one `comment_start` with the range, and Shift-click extends a composer. Publishing sends `start_line`/`start_side` when both ends are commentable.

**Tech Stack:** Elixir / Phoenix LiveView, vanilla JS hook, `gh api`.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` §Comments (Store `end_line`, Card ranges, Publishing multi-line), Part 3 (`add_comment` `end_line`), Milestones 7.1.

## Global Constraints

- Public repo: names within SampleApp/acme; `@moduledoc`/`@doc`/`@spec` on public functions, HEEx `attr`; comments state durable facts, never history. UI state server-owned except the textarea draft, the canvas view and the in-progress drag highlight. CSS via existing tokens.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build` (rebuild and commit `priv/static/assets/grasp.*`), `mix test`. Never `git add -A`; add by path. Trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Ranged threads end to end on the server

**Files:** modify `grasp/lib/grasp/comments.ex`, `grasp/lib/grasp/mcp/comments.ex` (`thread_map`, `check_line` reuse), `grasp/lib/grasp/mcp/tools/add_comment.ex`, `grasp/lib/grasp/comments/publisher.ex`, `grasp/lib/grasp/github.ex` (`create_review_comment/3` map gains `start_line`), `grasp/lib/grasp_web/live/review_live.ex` (`comment_start` with optional `end_line` and `shift`; `comment_save` passes `end_line`), `grasp/lib/grasp_web/components/card_components.ex` (thread placed at `end_line`, range tint via `data-commented` on covered lines, fold `keep` covers the range), `grasp/lib/grasp_web/components/comment_components.ex` (label `L12–L18`, composer heading "Lines 12–18"), `grasp/lib/grasp_web/components/sidebar.ex` (Comments row label), `grasp/assets/css/app.css` (`.line[data-commented]` tint from `--accent-soft`), `grasp/test/support/fake_gh.sh` (log already captures argv), tests: `comments_test.exs`, `mcp/comment_tools_test.exs`, `comments/publisher_test.exs`, `grasp_web/live/comments_live_test.exs`.

**Interfaces (produced):**

```elixir
# Grasp.Comments
thread gains end_line: pos_integer() | nil
add/2 accepts "end_line"/:end_line (optional): must be an integer > line, on the same side, inside the
  record's range for that side (validated where `line` is — reuse the existing line check for both);
  {:error, :invalid_end_line} otherwise. encode/decode write/read "end_line" (absent or null = nil).
@spec range(thread()) :: Range.t()          # line..(end_line || line)
# Grasp.MCP.Comments.thread_map/2: "end_line" => thread.end_line
# Tools.AddComment schema: end_line integer optional ("last line of a range; omit for one line")
# Grasp.Comments.Publisher: a thread with end_line whose line AND end_line are inside the diff ranges is a
#   :line comment with start_line: thread.line, line: thread.end_line (GitHub `start_line`/`start_side`);
#   a ranged thread with either end outside is a :file comment whose location paragraph reads
#   `Mod.fun/2` · L12–L18 (or `deleted lines 12–18`). Grasp.GitHub.create_review_comment/3 map gains
#   optional start_line: pos_integer(): when set adds -F start_line=N -f start_side=RIGHT.
# ReviewLive: "comment_start" %{"card","side","line", "end_line"?, "shift"?}
#   - no composer open, or a different card/side: composing = %{card, side, line: min, end_line: max | nil (when
#     equal or absent), reply_to: nil}
#   - "shift" => true with a composer open on the same card and side for a new thread: the composer's range
#     becomes min..max of its current first line and the clicked line (end_line nil when equal)
#   "comment_save" passes composing.end_line to Comments.add/2
# card_components: threads keyed by {side, end_line || line}; every line in a thread's range carries
#   data-commented (open threads only); Hunks.fold keep: every line of every placed thread's range.
```

**Requirements:**

- Placement: `Anchor.place/2` keeps working on `line`/snippet; when a ranged thread is anchored at a moved line `n`, its rendered range is `n..(n + end_line - line)` clamped to the record's last line (compute in the card component from the placement, not by changing the anchor).
- Sidebar row and the thread footer label read `L12–L18` for a range, `L12` otherwise.
- Composer heading (new thread): `Line 12` or `Lines 12–18`.
- Tests: `comments_test` — add with `end_line`, round trip, `end_line <= line` and out-of-range rejected, `range/1`; `comment_tools_test` — `add_comment` with `end_line`, listed with `"end_line"`, error on a bad one; `publisher_test` — a ranged thread inside greeter.ex 6..8 posts `start_line=6`, `line=8`, `start_side=RIGHT`, `side=RIGHT` (read from the fake gh log); a ranged thread reaching past the hunk (6..10) is a file comment with `L6–L10` in the body; `comments_live_test` — `comment_start` with `end_line` opens a composer reading `Lines 6–8`, save stores `end_line`, the thread renders under line 8 with lines 6–8 carrying `data-commented`, the label reads `L6–L8`; a Shift `comment_start` extends an open composer; the fold on a long synthetic record keeps a ranged thread's lines.
- Gates; commit `A comment can cover a range of lines`.

---

### Task 2: Drag along the line numbers

**Files:** create `grasp/assets/js/hooks/gutter.js`; modify `grasp/assets/js/app.js` (register `Gutter`), `grasp/lib/grasp_web/components/card_components.ex` (the card body element gets `phx-hook="Gutter"` — it needs an `id`; check it has one), `grasp/assets/js/hooks/canvas.js` only if a pointerdown on `.ln` still reaches it, `grasp/assets/css/app.css` (`.card__body[data-selecting] { user-select: none }`, `.line[data-selecting]` tint), `grasp/guides/reviewing.md` and README §Features one clause, spec if a detail differs.

**Interfaces (consumed):** Task 1's `comment_start` with `end_line` and `shift`.

**Requirements:**

- `Gutter` hook (mounted on `.card__body`): on `pointerdown` (button 0, no Ctrl/Meta) over `.ln`: record `{side, line}` from the element's `phx-value-*` attributes, `stopPropagation()` so the canvas hook never sees it, set `data-selecting` on the body and capture the pointer. On `pointermove` while selecting: find the `.ln` under the pointer (`document.elementFromPoint`) within the same body and side; tint every `.line` between the anchor and it (`data-selecting` on the line elements); the anchor line is always tinted. On `pointerup`: clear tints and the body flag; if the pointer ended on a different line than it started, `pushEvent("comment_start", {card, side, line: min, end_line: max})` and swallow the click that follows (a flag consumed by a `click` capture listener on the body, so the `.ln`'s own `phx-click` does not also fire); if it ended on the same line, do nothing — the `.ln`'s `phx-click` fires as today. Shift-click on a `.ln` (no drag) pushes `comment_start` with `shift: true` and swallows the phx-click.
- Keyboard: unchanged (Enter/Space on a focused `.ln` still opens a single-line composer).
- Pointer cancel / leaving the window clears the selection without pushing.
- Verify the canvas hook's pointerdown handler does not begin a pan or Ctrl-drag for a gutter press (read `canvas.js` `pointerDown`; a `.card` press without Ctrl is already ignored — confirm, and document in the hook's header comment why `stopPropagation` is still used: a Ctrl-press on the gutter belongs to the card drag, so the gutter ignores Ctrl).
- Docs: `grasp/guides/reviewing.md` Comments section — drag along the line numbers for a range, Shift-click to extend; README features clause "on any line or range of lines".
- Verification without a browser: `mix assets.build`, `node --check`, a written trace of one drag (down three lines) and one Shift-click in the report; list what only a browser confirms (elementFromPoint over the tinted line, text selection suppressed, the swallowed click).
- Gates; commit `Drag along the line numbers to comment on a range`.
