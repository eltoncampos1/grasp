# Grasp Chat Panel Upgrades Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The chat panel reads like the chat in Claude Code, Cursor or Copilot: the agent's Markdown renders as rich text with highlighted code fences, every `Mod.fun/arity` it names is a link that opens the card, text streams token by token, a reader always sees that the agent is working and on what, tool calls fold into a compact group with human labels and durations, each turn ends with its cost and time, the prompt is a multi-line box (Enter sends, Shift+Enter breaks a line), a prompt typed during a run is queued rather than refused, an empty transcript offers starting prompts, scrolling sticks to the bottom only while the reader is there, and a failed run shows its log inline with a Retry button.

**Architecture:** Rendering is server-side: `GraspWeb.ChatMarkdown` turns an assistant entry's text into safe HTML with MDEx (GitHub-flavoured Markdown, raw HTML sanitised), highlighting fenced code with Lumis so it matches the cards and turning function ids the index holds into `open_root` buttons. Streaming and working state come from the runner: `Grasp.Agent.Command` adds `--include-partial-messages`, `Grasp.Agent.Stream` folds `stream_event` text deltas into a partial assistant entry that the full `assistant` block later replaces, records when a run started and what each tool call took, and the view exposes `running?`, `started_at` and a `queue`. The panel derives "thinking" from the transcript's tail, groups consecutive tool entries, and the `Chat` hook owns only what a render cannot: the elapsed timer, Enter/Shift+Enter, prompt recall, sticky scrolling, and copy buttons. Everything else stays server state so a second tab sees the same panel.

**Tech Stack:** Elixir, Phoenix LiveView, MDEx (`~> 0.13`, Rust NIF with precompiled binaries like Lumis), Lumis, esbuild.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 3 §Chat panel (the bullets "Rendering", "Working state and streaming", "Tool rows", "Prompt box and queue", "Scrolling, failures, copying"), §Known gaps (milestone 7.4), §Milestones (7.4).

## Global Constraints

- Public repo: fixture names within `SampleApp`/`acme`; never name another project or a local path. `@moduledoc`/`@doc`/`@spec` on everything public; HEEx components document with `attr`/`slot` and carry no `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review" forbidden).
- Gates, from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build` (commit the rebuilt `grasp/priv/static/assets/grasp.js|grasp.css`), `mix test`. Read each exit code; never chain a commit on a failed gate. Never `git add -A`; stage by path; never stage `grasp/priv/static/assets/app.js|app.css` if untracked. Trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Tests never touch the network and never run the real `claude`: the CLI is `grasp/test/support/fake_claude.sh` (`:grasp, :agent_command` in `config/test.exs`); extend that script rather than adding a second one. Adding the MDEx dependency needs one `mix deps.get` on the developer machine (allowed) — pin `{:mdex, "~> 0.13"}` and commit `mix.lock`.
- The transcript is server state: a second tab must render the same panel from `Grasp.Agent.Runner`'s view alone. Client JS may hold only the prompt draft, the elapsed timer, scroll position and prompt history.
- Sanitisation is not optional: assistant text is model output; every HTML the panel renders from it passes MDEx's sanitiser with an explicit allow-list (verify option names against the installed MDEx: `MDEx.default_sanitize_options/0`).
- Verified stream facts: with `--include-partial-messages` the CLI emits lines `{"type":"stream_event","event":{...}}` wrapping the Anthropic streaming events — `message_start`, `content_block_start`, `content_block_delta` with `delta: {type: "text_delta", text}` or `{type: "input_json_delta", partial_json}`, `content_block_stop`, `message_delta`, `message_stop` — and still emits the full `assistant` message per block afterwards. `result` carries `duration_ms`, `num_turns`, `total_cost_usd`, `is_error`.

---

### Task 1: Markdown, code fences and function links

**Files:** modify `grasp/mix.exs`, `grasp/mix.lock`; create `grasp/lib/grasp_web/chat_markdown.ex`, `grasp/test/grasp_web/chat_markdown_test.exs`; modify `grasp/lib/grasp_web/components/chat_panel.ex`, `grasp/assets/css/app.css`, `grasp/test/grasp_web/live/chat_test.exs`, `grasp/test/support/fake_claude.sh`.

**Interfaces (produced):**

```elixir
# GraspWeb.ChatMarkdown
@spec render(String.t(), (String.t() -> boolean())) :: Phoenix.HTML.safe()
# `known?` says whether the index holds a function id (the panel passes
# &Grasp.Index.known?/1-style closure built from Grasp.IndexStore.get(): an id is known when
# Grasp.Index.fetch_function/2 finds it or finds the record whose `arities` include the written
# arity — reuse whatever ReviewLive's `canonical/2` uses). Pipeline:
#   MDEx.parse_document!(text, extension: [strikethrough: true, table: true, autolink: true, tasklist: true])
#   |> MDEx.traverse_and_update(fn
#        %MDEx.CodeBlock{info: info, literal: code} -> %MDEx.HtmlBlock{literal: fence_html(info, code)}
#        %MDEx.Code{literal: id} = node -> if function_id?(id) and known?.(id), do: %MDEx.HtmlInline{literal: link_html(id)}, else: node
#        %MDEx.Text{literal: text} = node -> split text on the id regex; ids that are known become HtmlInline links, the rest stay Text (return a list or the node)
#        node -> node end)
#   |> MDEx.to_html!(render: [unsafe: true], sanitize: allow_list())
# fence_html/2: Lumis.highlight(code, formatter: {:html_linked, language: lang}) when `lang` is one Lumis
#   knows (map `elixir ex exs`→"elixir", `heex`→"heex", `eex`→"eex", `erlang erl`→"erlang", `sh bash shell`→"bash",
#   `json`, `html`, `css`, `js javascript`, `diff` — check Lumis.languages/0 or equivalent and fall back to
#   `<pre><code>escaped</code></pre>` for anything else or when Lumis raises); wrapped as
#   `<pre class="fence" data-lang="…"><code>…</code></pre>`.
# link_html/1: `<button type="button" class="fn" phx-click="open_root" phx-value-id="ESCAPED">ESCAPED</button>`
# function_id?/1: ~r/\A(?:[A-Z]\w*\.)+[a-z_]\w*[?!]?\/\d+\z/  (text splitting uses the same body with \b-ish boundaries:
#   a match must not be preceded by a word character or `.`)
# allow_list/0: MDEx.default_sanitize_options() extended so that `class` is allowed on span, code, pre, div,
#   `data-lang` on pre, and `button` is allowed with `type`, `class`, `phx-click`, `phx-value-id`; `a` keeps
#   href/title with rel="noopener" and target="_blank" added via link_rel/`link_target` options if the
#   installed MDEx exposes them (otherwise leave links as sanitised). `<script>`, `<style>`, `on*` attributes
#   and `javascript:` hrefs are stripped by the sanitiser — test it.
```

**Requirements:**

- **Dependency.** `{:mdex, "~> 0.13"}` in `mix.exs`; `mix deps.get`; commit `mix.lock`. `mix compile` must pass without a Rust toolchain (precompiled NIF) — if it does not on this machine, stop and report.
- **Panel.** An assistant entry renders `{ChatMarkdown.render(entry.text, known?)}` inside `<div class="msg" data-type="assistant">`; user entries stay text. `white-space: pre-wrap` moves from the assistant message to `.msg[data-type="user"]` (Markdown owns its own line breaks); CSS for `.msg p`, lists, `code`, `.fence` (font `--mono`, background `--bg-sunken`, radius, padding, horizontal scroll), `table`, `blockquote`, and `.fn` (a button styled like an inline code span with the accent underline `.call` uses). Tokens only, no new colours.
- **Fake CLI.** Add to the canned run an assistant text block containing Markdown: a heading-less paragraph with `**bold**`, a fenced ```elixir block with one call, an inline code `SampleApp.Greeter.greet/2` (a function the fixture holds), an inline code `Nope.Missing.fun/1`, and a raw `<script>alert(1)</script>` line.
- **Tests.** `chat_markdown_test.exs`: bold renders `<strong>`; the fence renders `<pre class="fence" data-lang="elixir">` with Lumis spans (`class="l-…"`); an unknown language renders escaped `<pre><code>`; `SampleApp.Greeter.greet/2` with `known?` true → the `button.fn[phx-click=open_root][phx-value-id="SampleApp.Greeter.greet/2"]`; with `known?` false → stays `<code>`; a bare id in prose (not in backticks) is linked too; `Some.Thing/2`-shaped text inside a fence is NOT linked; `<script>` and `onclick` are stripped; a `javascript:` href is stripped; a table renders `<table>`. `chat_test.exs`: after the fake run, the panel contains `strong`, `pre.fence` and the `button.fn` for the greeter; clicking that button opens a root card for `SampleApp.Greeter.greet/2`; the script text is absent from the rendered HTML.
- Gates incl. `mix assets.build`; commit `The agent's answers render as Markdown with links to the cards` with the trailer.

### Task 2: Streaming, working state, tool groups and turn footers

**Files:** modify `grasp/lib/grasp/agent/command.ex`, `grasp/lib/grasp/agent/stream.ex`, `grasp/lib/grasp/agent/runner.ex`, `grasp/lib/grasp_web/components/chat_panel.ex`, `grasp/assets/js/hooks/chat.js`, `grasp/assets/css/app.css`, `grasp/test/support/fake_claude.sh`; tests `command_test.exs`, `stream_test.exs`, `runner_test.exs`, `chat_test.exs`.

**Interfaces (produced):**

```elixir
# Grasp.Agent.Command.build/2 argv gains "--include-partial-messages" (test pins it).

# Grasp.Agent.Stream
@type entry ::
        %{type: :user, text: String.t()}
        | %{type: :assistant, text: String.t(), partial: boolean()}
        | %{type: :tool, name: String.t(), summary: String.t(), status: :running | :done | :error,
            started_at: integer(), ms: non_neg_integer() | nil, detail: String.t() | nil}
        | %{type: :error, text: String.t()}
        | %{type: :done, cost_usd: float() | nil, turns: integer() | nil, ms: integer() | nil}
# event "stream_event": event["event"]["type"] == "content_block_delta" and delta type "text_delta" →
#   append delta text to the last entry when it is a partial assistant entry, else append a new
#   %{type: :assistant, text: delta, partial: true}. Every other stream_event is ignored.
# event "assistant" text block: when the last entry is a partial assistant entry, REPLACE its text with the
#   block's text and set partial: false (the block is the authoritative full text); otherwise as today.
# tool_use: started_at = System.monotonic_time(:millisecond) (inject a clock through an option or module
#   attribute so tests can pin ms; simplest: store started_at and compute ms on close from the same clock).
# tool_result: closes the oldest running tool with status and ms = now - started_at; when is_error, detail =
#   the result content as text (string, or the text of the first text block), trimmed to 2000 chars.
# result: :done gains ms = event["duration_ms"].

# Grasp.Agent.Runner view/1 gains started_at: integer() | nil (System.system_time(:millisecond) when the
#   port opened; nil when idle) so the client can show elapsed time.

# GraspWeb.ChatPanel
# label/1 for tool entries (human text): "search_functions" → ~s(Searched "#{summary}"); "get_function" →
#   "Read #{summary}"; "get_callers" → "Callers of #{summary}"; "get_callees" → "Callees of #{summary}";
#   "find_paths" → "Traced paths"; "list_changes" → "Listed the changes"; "list_entry_points" → "Listed entry
#   points"; "set_cards" → "Arranged #{summary}" (summary is "N cards"); "open_card" → "Opened #{summary}";
#   "publish_comments" → "Published the comments"; "reload_index" → "Reloaded the index"; "Read" → "Read
#   #{summary}"; "Grep" → ~s(Searched files for "#{summary}"); "Glob" → "Listed #{summary}"; "Edit"/"Write" →
#   "Edited #{summary}"/"Wrote #{summary}"; "Bash" → "Ran #{summary}"; anything else → "#{name} #{summary}" trimmed.
```

**Requirements:**

- **Transcript layout.** Consecutive `:tool` entries render as one `<details class="tools" open={running?}>` with `<summary>Used N tools</summary>` ("Used 1 tool"), each row `<div class="tool" data-status=…>` showing the label, a status glyph (running: CSS spinner; done: ✓; error: ✕) and `ms` as "1.2 s"/"340 ms" when present; an error row shows `detail` in a `<pre>` under it. Group open while any row is running, closed otherwise (server-decided via the `open` attribute).
- **Working state.** While `running?` and the last entry is a `:user`, a finished `:tool` group, or a partial-less assistant text: a `<div class="msg" data-type="thinking">` with three dots animated by CSS (`@keyframes`, `prefers-reduced-motion` respected). A status line `<div class="chat__status">` under the log while running: `Working · <span data-elapsed-from={@agent.started_at}>0s</span> · N tool calls` (N = tools since the last `:user`); the `Chat` hook ticks the elapsed span every second from the epoch in the attribute and stops when the attribute is gone. Send becomes a Stop button while running (one button, `phx-click="chat_stop"`, `type="button"`), so the form has one primary control; New stays.
- **Footer.** `:done` renders `<div class="msg" data-type="done">$0.01 · 2 turns · 4.2 s</div>` (each part only when present).
- **Fake CLI.** Before the first assistant text block, emit two `stream_event` lines with text deltas `"Looking"` and `" at the flow."` (the full block that follows carries the joined text); make tool result `t1` carry a small delay is NOT needed. Add a second tool call `t2` (`mcp__grasp__set_cards`, `{"cards":[…3 items…]}`) whose `tool_result` has `is_error: true` and content `"no such function"`. Add `"duration_ms": 4200` to the result line.
- **Tests.** `command_test`: argv includes `--include-partial-messages`. `stream_test`: deltas build a partial entry; the full block replaces it (no duplication); a delta with no prior assistant entry creates one; an `input_json_delta` changes nothing; tool `ms` set on close (use two `apply` calls with an injected clock, or assert `is_integer(ms)`); error detail captured and trimmed; `:done.ms`. `runner_test`: view carries `started_at` during a SLOW run and nil after. `chat_test`: during a SLOW run the thinking row or the open tools group is present and the status line reads "Working"; after the run, `details.tools summary` reads "Used 2 tools", the error row shows "no such function", the done row shows "$0.01 · 2 turns · 4.2 s"; the assistant text reads "Looking at the flow." exactly once.
- Gates incl. `mix assets.build`; commit `The chat shows the agent working, streams its words and folds its tools` with the trailer.

### Task 3: Prompt box, queue, suggestions, scrolling, failures, copying

**Files:** modify `grasp/lib/grasp/agent/runner.ex`, `grasp/lib/grasp/agent.ex` (facade, if it wraps runner calls), `grasp/lib/grasp_web/components/chat_panel.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/js/hooks/chat.js`, `grasp/assets/css/app.css`; tests `runner_test.exs`, `chat_test.exs`; docs `grasp/guides/agent.md`, `README.md`/`grasp/README.md` (one line each if they describe the chat).

**Interfaces (produced):**

```elixir
# Grasp.Agent.Runner
# state gains queue: [String.t()]. {:prompt, text, opts} while running → the prompt is appended to queue and
#   the reply is {:ok, :queued}; view gains queue: [String.t()]. When the port exits (any status) and the
#   run was not stopped by the user, the head of the queue starts as the next run (same opts as the last
#   prompt; keep the last opts on state); Stop clears the queue; New clears the queue. {:dequeue, index}
#   removes one queued prompt.
# Grasp.Agent gets dequeue/2 and the ReviewLive events "chat_dequeue" (index), "chat_retry" (re-sends the
#   last :user entry's text), "chat_suggest" (%{"prompt" => text} → same path as chat_send).
```

**Requirements:**

- **Prompt box.** `<textarea id="chat-prompt" rows="1" phx-update="ignore">`; the hook grows it to fit up to 6 rows, submits the form on Enter without Shift (`form.requestSubmit()`), inserts a newline on Shift+Enter, and recalls the last sent prompt on ArrowUp when the box is empty (history kept in the hook, last 20). Send stays enabled during a run (it queues). Placeholder "Ask about a flow… (Enter to send, Shift+Enter for a new line)".
- **Queue.** Queued prompts render under the log as `<div class="msg" data-type="queued">` with the text and an × button (`chat_dequeue`). A test: send during a SLOW run → `{:ok, :queued}`-driven UI shows the queued row; after the first run ends, the transcript has two `:user` entries and the second run's output; Stop during a run empties the queue.
- **Suggestions.** When `entries == []` and not running, render `<div class="chat__suggest">` with buttons (`phx-click="chat_suggest"`): "Show me what changed" (only when the index is in PR mode — `Grasp.Index.changed_functions/1` non-empty or the document's git block has a base), "Explain {focused card's id}" (when a card is focused — the LiveView knows the focus), "Publish the comments" (when `Grasp.Comments` has threads), always "Where does {an entry point label} lead?" for the first route entry point when there is one. Clicking sends the prompt exactly as typed.
- **Scrolling.** The hook records whether the log is within 24 px of its bottom on every `scroll` event; `updated()` scrolls to the bottom only when it was; otherwise a `#chat-jump` pill ("↓ latest", client-toggled `hidden`) appears and scrolls down on click. A submit always scrolls to the bottom.
- **Failures.** A run that ends in an `:error` entry with a non-empty log renders the log inline under the error in a `<details open>` (replacing the separate `chat__debug` disclosure) and a "Retry" button (`chat_retry`) that re-sends the last prompt; the FAIL fake path covers it: after FAIL, clicking Retry starts a run whose transcript shows the prompt twice.
- **Copying.** Each assistant message gets a `<button class="copy" data-copy="msg">` (top-right, visible on hover) and each `pre.fence` a `<button class="copy" data-copy="pre">`; the hook delegates clicks, writes `innerText` of the target to `navigator.clipboard`, and flips the label to "Copied" for 1.5 s. Buttons on fences are injected by the hook after each `updated()` (idempotent: skip a `pre` that already has one), since the fence HTML comes from the Markdown renderer. No test for the clipboard itself; a test asserts the message copy button renders.
- **Docs.** `grasp/guides/agent.md`: a short "The panel" section describing Markdown, function links, streaming, tool groups, Enter/Shift+Enter, the queue, suggestions, Retry and copy. Durable facts only.
- Gates incl. `mix assets.build`; commit `The prompt box grows, queues and suggests, and a failed run can be retried` with the trailer.
