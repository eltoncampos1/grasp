# Grasp PR Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `mix grasp.index --base REF` classifies every function as added, modified, removed or unchanged against a git base ref and stores the base source; the viewer shows change badges, a Changes sidebar grouped by module, and a per-card Source/Diff toggle rendering a unified diff whose current-side lines keep their clickable calls; MCP gains `list_changes` and `set_view`.

**Architecture:** In `grasp_index`, `Grasp.Index.BaseRef` talks to git (merge-base, changed files including uncommitted and untracked, `git show` of base files) and `Grasp.Index.Changes` is pure: it runs `Extract` over the base sources and matches definitions by id to classify the current records and synthesise removed ones. In the viewer, `Grasp.Diff` wraps `List.myers_difference/2`, `Grasp.Highlight.render_diff/2` reuses the per-line piece pipeline for current-side lines and a cached parse of the base source for removed lines, the card gets a `view` field in the forest, and the sidebar gets a Changes group.

**Tech Stack:** Elixir, Sourceror (existing), git CLI via `System.cmd/3`, Phoenix LiveView 1.2, Lumis.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 step 5 (Base ref), Index JSON (`git`, `change`, `base_source`, `removed`), Part 2 §Session (`view`), §Page (Changes list), §Card (change badge, Source/Diff toggle), §Highlighting and diffs, Part 3 (`list_changes`).

## Global Constraints

- Public repo: no real company, product or private project names; fixtures are `SampleApp`.
- `@doc`/`@spec` on every public function, `@moduledoc` on every module, HEEx components use `attr`/`slot`; comments state durable whys.
- `grasp_index` must keep zero runtime deps beyond sourceror and jason; git is reached only through `System.cmd/3` and its absence degrades (no `--base`: as today; `--base` given but git or the ref missing: `Mix.raise` with a plain message).
- Whitespace-only edits count as modified (byte comparison of the function source); a renamed function is one removed plus one added; the base side is parsed, never compiled, so base records carry no calls.
- Tests async where possible; temp git repos live under `System.tmp_dir!()` with unique names and are removed in `on_exit`; git identity is set per repo (`git -c user.name=… -c user.email=…` or `git config` inside the temp repo) so CI machines without a global identity pass.
- Gates per package: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (grasp_index also `--include integration`), and `mix assets.build` for the viewer. Today: grasp_index 57, grasp 228. Never delete a test without a replacement. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Base ref in the indexer

**Files:**
- Create: `grasp_index/lib/grasp/index/base_ref.ex`, `grasp_index/lib/grasp/index/changes.ex`
- Modify: `grasp_index/lib/grasp/index/builder.ex`, `grasp_index/lib/mix/tasks/grasp.index.ex`, `grasp_index/lib/grasp/index/join.ex` (only if `function_record` needs the new keys typed there — prefer typing them in `Changes`)
- Test: `grasp_index/test/grasp/index/base_ref_test.exs`, `grasp_index/test/grasp/index/changes_test.exs`, extend `grasp_index/test/grasp/index/builder_test.exs` only with a JSON-shape assertion (`"change" => "unchanged"`, `"removed" => false`, `git["base_ref"] == nil` when no base is given)

**Interfaces:**

```elixir
Grasp.Index.BaseRef.resolve(root, ref) :: {:ok, %{base_ref: String.t(), base_sha: String.t(), files: [path], base_sources: %{path => String.t()}}} | {:error, String.t()}
  # base_sha = `git merge-base REF HEAD`, falling back to `git rev-parse --verify REF^{commit}` when
  # merge-base fails (a ref with no common history); error strings: "not a git repository",
  # "unknown ref: REF", "git is not installed".
  # files = (`git diff --name-only BASE_SHA` ∪ `git ls-files --others --exclude-standard`), kept when
  # the extension is .ex or .exs and the path starts with one of `paths` (an option, default ["lib"]);
  # sorted, unique. base_sources: for each file, `git show BASE_SHA:path` → content; a file absent
  # from the base (added) is simply not in the map.
Grasp.Index.Changes.classify(records, base_sources, paths) :: [record]
  # records: the current Join records (maps with :id, :source, …). Runs Extract.extract/2 over each
  # base source (file → definitions); base_ids = %{Join.function_id(m, n, arity) => definition} for
  # the definition's own :arity. For every current record whose :file is in base_sources' keys OR
  # whose id is in base_ids: change = "added" when the id is not in base_ids, "unchanged" when the
  # base definition's source == record.source, else "modified" with base_source. Records in files
  # untouched by the diff are "unchanged". Every base id with no current record becomes a removed
  # record: %{id, module, name, arity, arities, kind, file (base path), span (base start/end),
  # source: base source, calls: [], hidden_calls: [], change: "removed", base_source: base source,
  # removed: true}. Output keeps the input order, removed records appended sorted by id.
Grasp.Index.Builder.run(opts) # gains `base: REF | nil`; document["git"] carries base_ref/base_sha;
  # summary gains :changed (count of records whose change != "unchanged", removed included).
mix grasp.index --base REF   # `--base` string switch; raise the BaseRef error string via Mix.raise
```

Record JSON: `function_json/1` emits `record.change`, `record.base_source`, `record.removed` (defaulting to the current literals when the keys are absent, so a build without `--base` is unchanged).

- [ ] **Step 1: Failing tests.** `changes_test.exs` (pure, `async: true`): build two small sources by hand — base `lib/a.ex` with `A.f/0`, `A.g/1` and `A.h/0`; current records for `A.f/0` (same text), `A.g/1` (one line changed), `A.new/0` (not in base); expect f unchanged, g modified with `base_source`, new added, and a removed record for `A.h/0` with `removed: true`, `calls: []`, `source == base_source`; a record whose file is not among the base sources is unchanged even though its id is unknown in the base (it lives in an untouched file). Also: a function present in base file `lib/a.ex` and current file `lib/b.ex` with identical text is unchanged (matched by id across files).
  `base_ref_test.exs` (`async: false` is fine — it shells out): make a temp repo: `git init -q`, set identity, write `lib/a.ex` and `lib/keep.ex`, commit; create branch `feature` (or just commit on the same branch after tagging `base`): modify `lib/a.ex`, add `lib/b.ex` (untracked, not committed), delete `lib/keep.ex`, add `README.md`; `resolve(root, "base")` returns `files == ["lib/a.ex", "lib/b.ex", "lib/keep.ex"]`, `base_sources` has `lib/a.ex` and `lib/keep.ex` but not `lib/b.ex`, `base_sha` is the tag's commit; `resolve(root, "nope")` → `{:error, "unknown ref: nope"}`; `resolve(System.tmp_dir!(), "main")` (not a repo) → `{:error, "not a git repository"}`.
- [ ] **Step 2: Implement** per the interfaces; wire `Builder.run/1` (after `Join.join/2`: `records = if base, do: Changes.classify(functions, base_sources, paths), else: functions`) and the `git` block; `EntryPoints`/`indexed` should use the current records only (removed functions are not indexed definitions). Update the task's `@moduledoc` and `@switches`.
- [ ] **Step 3: Gates and commit** — `cd grasp_index && mix format && mix compile --warnings-as-errors && mix test --include integration`. Commit: `Indexer: classify functions against a git base ref`.

---

### Task 2: Diff view, change badges, removed cards

**Files:**
- Modify: `grasp/lib/grasp/session/forest.ex` (`view` on the card, `set_view/3`, `toggle_view/2`, `to_map` gains `"view"`), `grasp/lib/grasp/session.ex` (`toggle_view/2`, `set_view/3`), `grasp/lib/grasp/highlight.ex` (`render_diff/2`), `grasp/lib/grasp_web/components/card_components.ex`, `grasp/lib/grasp_web/live/review_live.ex` (`toggle_view` event, `d` key handler `toggle_view_focused`), `grasp/assets/js/hooks/keys.js` (`d`), `grasp/assets/css/app.css`, `grasp/test/fixtures/index.json`
- Create: `grasp/lib/grasp/diff.ex`
- Test: `grasp/test/grasp/diff_test.exs`, `grasp/test/grasp/highlight_test.exs`, `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`

**Fixture edits (hand-made, documented in the report):** in `grasp/test/fixtures/index.json` set `git` to `{"head": "0000000", "branch": "feature", "base_ref": "main", "base_sha": "1111111"}`; mark `SampleApp.Formatter.shout/1` `"change": "modified"` with a `base_source` equal to its `source` with the `String.upcase` line replaced by `    text` (any one-line difference); mark `SampleApp.Greeter.Nested.hello/0` `"change": "added"`; append a removed record `SampleApp.Formatter.whisper/1` (`module` SampleApp.Formatter, `name` whisper, arity 1, kind def, file `lib/sample_app/formatter.ex`, span 20–22, `source` and `base_source` both `"  def whisper(text) do\n    String.downcase(text)\n  end"`, `calls: []`, `hidden_calls: []`, `change: "removed"`, `removed: true`). Everything else unchanged.

**Interfaces:**
```elixir
Grasp.Diff.lines(base :: String.t(), current :: String.t()) :: [{:eq | :del | :ins, String.t()}]
  # List.myers_difference over String.split(_, "\n"), flattened in order.
Grasp.Diff.stats(base, current) :: %{added: n, removed: n}
Grasp.Highlight.render_diff(record, opts) :: Phoenix.HTML.safe()
  # same opts as render/2. Lines: `<span class="line" data-op="eq|ins|del" data-line=N>` where N is
  # the CURRENT line number for eq/ins (counting from span.start_line through eq+ins lines) and
  # absent for del; gutter `<span class="ln">` shows N or "" and a `<span class="op">` shows " ",
  # "+" or "−". eq/ins bodies go through the existing pieces/split/wrap pipeline for that current
  # line (so open calls, colours and highlights work); del bodies use pieces parsed from
  # base_source (cache key `id <> "@base"`, first line 1 → map del index to its base line) with
  # no call wrapping. A record with nil base_source renders like render/2.
Forest card gains `view: :source | :diff` (default :source); Forest.set_view/3, Forest.toggle_view/2;
Session.set_view/3, Session.toggle_view/2; to_map card gains "view" => "source" | "diff".
```

Card component: a change badge before the title — `<span class="badge badge--change" data-change={change}>` with text `added` / `modified` / `removed` (no badge for unchanged); for modified a second `<span class="card__stats">+3 −1</span>` from `Diff.stats/2`; a Source/Diff toggle button `#view-N` (`phx-click="toggle_view"`, `phx-value-card`) only when `change == "modified"`, showing `diff` when the view is source and `source` when diff; the body renders `render_diff` when `card.view == :diff`. Removed records: `class="card card--removed"` (`--diff-del-bg` tint on the header, the body rendered normally from `source`), no toggle, footer "Also calls" naturally empty. `data-view` on the article. Keyboard `d` toggles the focused card's view (`toggle_view_focused`, no-op when the card is not modified).

CSS tokens: `--diff-ins-bg: #dafbe1; --diff-del-bg: #ffebe9; --diff-ins-fg: #1a7f37; --diff-del-fg: #cf222e;`; rules: `.line[data-op="ins"] { background: var(--diff-ins-bg); }`, `.line[data-op="del"] { background: var(--diff-del-bg); }`, `.op { display: inline-block; width: 1ch; margin-inline-end: var(--space-xs); color: var(--fg-faint); }`, `.line[data-op="ins"] .op { color: var(--diff-ins-fg); }`, `.line[data-op="del"] .op { color: var(--diff-del-fg); }`, `.badge--change[data-change="added"] { background: var(--diff-ins-bg); color: var(--diff-ins-fg); }`, modified → `var(--accent-soft)`/`var(--accent)`, removed → del colours; `.card--removed .card__header { background: var(--diff-del-bg); }`.

- [ ] **Step 1: Failing tests.** `diff_test.exs`: `lines("a\nb\nc", "a\nx\nc") == [eq: "a", del: "b", ins: "x", eq: "c"]`, `stats/2` counts, identical inputs → all eq, empty base → all ins. `highlight_test.exs`: `render_diff` on a record with a one-line change renders one `.line[data-op="del"]` with no `data-line`, one `ins` with the right `data-line`, and an `eq` line that still carries a `.call` span when the change is above it; the del line's text is present. `forest_test.exs`: `toggle_view` flips source→diff→source, `set_view` validates the atom, `to_map` shows `"view"`. `review_live_test.exs`: (a) the modified fixture card shows `.badge--change[data-change="modified"]`, `.card__stats` with `+1 −1`, and `#view-N` reading `diff`; clicking it renders `.line[data-op="del"]` in the body and the button reads `source`; (b) the added card shows the added badge and no toggle; (c) opening `SampleApp.Formatter.whisper/1` renders `.card--removed` with the removed badge and its base text; (d) pressing `d` (send `toggle_view_focused`) on the focused modified card flips the view; on an unchanged card nothing changes.
- [ ] **Step 2: Implement.** Keep `render/2` untouched in behaviour; factor the per-line body builder so both renderers share it.
- [ ] **Step 3: Gates and commit** — `cd grasp && mix format && mix compile --warnings-as-errors && mix assets.build && mix test`. Commit: `Diff view, change badges and removed cards`.

---

### Task 3: Changes sidebar, palette badges, MCP, docs

**Files:**
- Modify: `grasp/lib/grasp_web/components/sidebar.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp_web/components/palette.ex`, `grasp/lib/grasp/agent/command.ex` (system prompt: add "For questions about what a change does, start from list_changes and trace each changed function to its entry points with find_paths."), `grasp/lib/grasp/mcp/server.ex`, `README.md`, `docs/specs/2026-09-15-grasp-design.md`
- Create: `grasp/lib/grasp/mcp/tools/list_changes.ex`, `grasp/lib/grasp/mcp/tools/set_view.ex`
- Test: `grasp/test/grasp_web/components/sidebar_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`, `grasp/test/grasp_web/live/palette_test.exs`, `grasp/test/grasp/mcp/tools_test.exs`, `grasp/test/grasp/mcp/session_tools_test.exs`, `grasp/test/grasp_web/mcp_test.exs` (tools/list now includes the two names)

**Requirements:**
- Sidebar: when `Index.changed_functions/1` is non-empty, a first group `data-kind="changes"` titled `Changes` with the count, expanded by default, rows grouped by module (`.group__heading` per module as the routes group does per router), each row `button.entry[phx-click="open_root"][phx-value-id]` reading `fn/arity` with a `.badge--change[data-change]` before it. `Sidebar.group_kinds/0` includes `"changes"`; `default_expanded/1` includes it when there are changes; the sidebar project line shows `base_ref` when the index has one (`main…feature`).
- Palette results show the change badge after the id when the record is changed.
- MCP: `list_changes` (no params) → `%{"total" => n, "base_ref" => ref | nil, "changes" => [%{"id","change","file","line","module"}]}` sorted by id; `set_view(session, card_id, view: "source" | "diff")` → forest JSON; unknown card → error; `view: "diff"` on a card whose function is not modified → error `"no diff for <id>"`. `get_function` result gains nothing (it already carries `change`; `base_source` stays out).
- README: a "PR mode" section (`mix grasp.index --base main`; what changes are detected; the Changes group; the diff toggle and `d`; removed cards). Spec: Known gaps (milestone 5) — whitespace-only edits are modified; renames are removed+added; the base side is never compiled so a removed function has no callers/callees and a modified function's calls are the current ones only; uncommitted and untracked changes are included; the diff is line-based with no intra-line highlighting.
- Gates in `grasp/`, all green; commit `Changes sidebar, palette badges, list_changes and set_view`.
