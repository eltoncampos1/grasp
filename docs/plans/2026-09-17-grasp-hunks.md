# Grasp Changes-Only Diff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A card in diff view can show only the changed hunks with three lines of context on each side, the unchanged stretches folded behind a row that expands on click, as GitHub does. A function longer than 100 lines opens folded; a shorter one opens with every line. A header toggle switches between the two.

**Architecture:** Folding is a pure function over the per-line list `Grasp.Highlight.diff_lines/2` already produces (each entry gains its diff `op`), living in `Grasp.Diff.Hunks`. The card's preference is session state on the card (`context: :auto | :hunks | :full`, `Forest.effective_context/2`), like `view`; which folds a tab has opened is that tab's own (`expanded_folds`). Lines carrying a comment thread are never folded.

**Tech Stack:** Elixir / Phoenix LiveView.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` §Highlighting and diffs (the "changes only" paragraph), §Session (`context` on a card), Part 3 (`set_view` `context`).

## Global Constraints

- Public repo; no names beyond `SampleApp`. `@moduledoc`/`@doc`/`@spec` everywhere public; HEEx `attr`; comments state durable facts, never history. UI state server-owned except the textarea draft and the canvas view/mode. CSS via tokens.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test`. Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Folding hunks and the card's context preference

**Files:** create `grasp/lib/grasp/diff/hunks.ex`, `grasp/test/grasp/diff/hunks_test.exs`; modify `grasp/lib/grasp/highlight.ex` (line entries gain `op`), `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp/mcp/tools/set_view.ex`, `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/css/app.css`, README §PR mode, spec; tests `highlight_test.exs`, `forest_test.exs`, `session_tools_test.exs`, `review_live_test.exs`.

**Interfaces (produced):**

```elixir
# Grasp.Highlight
@type line :: %{side: :new | :old, line: pos_integer(), op: :eq | :ins | :del, html: String.t()}
# lines/2 yields op: :eq for every entry; diff_lines/2 the diff's op.

# Grasp.Diff.Hunks
@type fold :: %{fold: true, from: pos_integer(), to: pos_integer(), count: pos_integer()}
@spec fold([Grasp.Highlight.line()], keyword()) :: [Grasp.Highlight.line() | fold()]
# opts: context: 3 (default), keep: MapSet of {side, line} that must stay visible (threads),
#       expanded: MapSet of `from` line numbers whose fold the reader opened.
# Rule: an entry is an anchor when op != :eq or {side, line} ∈ keep; the `context` entries
# on either side of an anchor stay; every maximal run of remaining :eq entries of length > 1
# becomes one fold naming the first and last current line (`from`/`to`) and its `count`
# (a run of exactly 1 is left in place — a fold row is taller than the line it would hide);
# a fold whose `from` ∈ expanded is emitted as its lines. A list with no anchor at all folds
# to a single fold when longer than 1. :old entries never carry current line numbers, so a
# fold's from/to are taken from :new-side entries in the run; a run made only of :old
# entries cannot occur (deleted lines are anchors).

# Grasp.Session.Forest
@type context :: :auto | :hunks | :full
card gains context: :auto (in add_card, to_map "context" => string, replace/1 spec optional :context)
set_context(t, id, context) :: t        # no-op on unknown id; guard on the three atoms
toggle_context(t, id, loc) :: t          # :auto resolves through effective_context/2 first
effective_context(context, loc) :: :hunks | :full   # :auto → :hunks when loc > 100 else :full
# Grasp.Session: set_context/3, toggle_context/3 wrappers.
```

**Requirements:**

- **Card.** In diff view (`effective_view == :diff` and diffable), `function_card/1` computes `loc = record["source"] |> String.split("\n") |> length()`, `context = Forest.effective_context(card.context, loc)`, and when `:hunks` passes the lines through `Hunks.fold/2` with `keep` = the anchors of the card's placed threads and `expanded` = this tab's `expanded_folds` for this card. A fold renders as `<button class="line line--fold" phx-click="expand_fold" phx-value-card={id} phx-value-from={from}>⋯ {count} unchanged lines</button>` (singular for 1 is unreachable). The header gains, beside the `diff`/`source` toggle and only while the diff is shown, `<button id={"context-#{id}"} class="card__context" phx-click="toggle_context" phx-value-card={id} title="Show every line or only the changes (h)">` reading `all lines` when folded and `changes only` when full. Source view ignores `context`. The card carries `data-context="hunks|full"` when in diff view.
- **LiveView.** Assign `expanded_folds: MapSet.new()` (per tab; entries `{card_id, from}`); events `toggle_context` (`card`) → `Session.toggle_context(name, id, loc)` with `loc` computed from the record (nil record → no-op); `toggle_context_focused` for the `h` key in `keys.js`; `expand_fold` (`card`, `from`) adds to the set. Prune `expanded_folds` against the forest like `selected`. The card's `open_calls`/threads interleaving is unchanged; folded lines simply are not rendered, so an edge from a folded call site is drawn from the card's port (the hook already handles a call site with no box).
- **MCP.** `set_view` gains optional `context` (`"hunks" | "full" | "auto"`); with `view` still required. `Forest.to_map/1` writes `"context"`. `set_cards` specs accept optional `context` the same way they accept `view`? — they do not accept `view` today; leave `set_cards` alone.
- **Stats.** Unchanged.
- **CSS.** `.line--fold { display: block; width: 100%; text-align: start; padding-inline: var(--space-s); color: var(--fg-muted); background: var(--bg-sunken); font-family: var(--mono); font-size: var(--code-size); }` with a hover tint; `.card__context` like `.card__view`.
- **Tests.** `hunks_test.exs`: a synthetic list of 20 `:eq` lines with one `:ins` at 10 folds to `[fold 1..6 (6), eq 7,8,9, ins 10, eq 11,12,13, fold 14..20 (7)]`; two anchors closer than 2×context merge their context (no fold between); a run of exactly one `:eq` between contexts is kept as a line; `keep` prevents folding of a commented line; `expanded` opens a fold; no anchors → one fold; `:del` lines are anchors and do not break `from`/`to` numbering. `highlight_test`: entries carry `op`. `forest_test`: `effective_context` at 100 and 101 lines; `toggle_context` from `:auto` on a long function → `:full`, on a short one → `:hunks`; `to_map` writes `"context"`. `session_tools_test`: `set_view` with `context: "hunks"`. LiveView: `SampleApp.Formatter.shout/1` (short) opens in diff view with `data-context="full"` and no fold; a card whose record is > 100 lines is not in the fixture — cover the long case at the forest level and, in the LiveView, click `#context-N` on `shout/1` and assert `data-context="hunks"` and that the fixture's diff renders at least one `.line--fold` if its unchanged stretch is long enough (check the fixture; if not, assert only the attribute), then `expand_fold` reveals the folded lines.
- README §PR mode: the toggle, the 100-line default, `h`. Spec paragraph in §Highlighting and diffs.
- Gates; commit `Diff view can show the changes alone, folded like a pull request`.
