# Grasp Interpolations as Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A call written inside a template — `{SampleApp.Greeter.greet(@name)}` in a tag body, `class={helper(@x)}` in an attribute, `<%= if allowed?(@user) do %>` in an expression tag — is a clickable call on the card holding the `~H` or on the `.heex` record, exactly like a component tag or a call in a clause body. Today those calls are hidden calls in the "Also calls" footer, so the controller → template → context chain cannot be clicked through.

**Architecture:** The compiler reports a `{…}` interpolation's calls with the interpolation's line and **no column**, and an EEx expression tag's calls with their **file column**. `Grasp.Index.Heex` learns to yield every interpolation and expression body with its file position (continuation lines re-indented so a parse yields file coordinates); `Grasp.Index.Extract` parses each body with Sourceror at that position and collects call sites from the AST with the very same walk it uses for clause bodies, so each site's range covers the callee only. Every site now also carries the callee as written (`callee: %{module, name, arity}`), and `Grasp.Index.Join` gains one step for a column-less event: before the hidden-call rule, take the first unclaimed site on the event's line with the same name and arity whose written module, if any, is a suffix of the event's target module. Expression-tag sites already carry the column the compiler reports, so they join through the existing positional lookup. `Grasp.Index.Templates` uses the combined template scan for `.heex` records, and the incremental path inherits everything because it calls the same three modules.

**Tech Stack:** Elixir, Sourceror (`parse_string/2` with `:line` and `:column`), the Elixir compiler tracer, Phoenix LiveView (viewer tests).

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 §Pipeline step 3 (column-less events placed by name), §Templates fourth part "Interpolations are code", §Known gaps (milestone 6.1) first bullet, §Milestones (7.2).

## Global Constraints

- Public repo: fixture names stay within `SampleApp`/`acme`; never name any other project or a local filesystem path. `@moduledoc`/`@doc`/`@spec` on everything public; comments state durable facts, never history ("was", "now", "previously", "per review" are forbidden in code and docs).
- Gates, run from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (its exit code decides — read it, never chain a commit on a failed gate). Task 2 also runs `mix test --include integration` (compiles `test/fixtures/sample_app`). Never `git add -A`; add files by path. Never stage `grasp/priv/static/assets/app.js` or `app.css` if they appear untracked (an external watcher writes them). Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Facts of the sample app that viewer tests pin and no task may move: `SampleApp.Greeter.greet/2` spans lines 6..11 of `lib/sample_app/greeter.ex`; `SampleApp.Formatter.shout/1` spans 8..10; do not edit `greeter.ex` or `formatter.ex`. In `greet_html/show.html.heex`, lines 1–4 stay exactly as they are (line 1 `<.badge label="hi" />`, line 2 the remote component tag, line 3 the `<a href>`, line 4 `<p>{SampleApp.Greeter.greet(@name)}</p>`); new lines are appended after line 4 only. `hello_live.ex` and `greeting_component.ex` are not edited (their render/1 records are pinned by line in join/builder tests).
- Verified compiler facts (from a tracer probe on phoenix_live_view 1.2.11, the version in `grasp/mix.lock`), which the tests below encode: `<p>{Mod.f(@x)}</p>` and `class={g(@x)}` report `line` = the line the call's name is on and `column: nil`; a call spanning lines (`{Mod.f(\n  @x)}`) reports the line of `Mod.f`; `<%= if g(@x) do %>` reports `g/1` at its file line AND file column (heredoc indentation included, i.e. the same coordinates the file has); a component tag inside an EEx block keeps its column as before. Local calls arrive as `:local` kind events; remote as `:remote`; imported as `:imported`.

---

### Task 1: Interpolation sites in the indexer, and the join that places them by name

**Files:** modify `grasp/lib/grasp/index/heex.ex`, `grasp/lib/grasp/index/extract.ex`, `grasp/lib/grasp/index/join.ex`, `grasp/lib/grasp/index/templates.ex`; tests `grasp/test/grasp/index/heex_test.exs`, `grasp/test/grasp/index/extract_test.exs`, `grasp/test/grasp/index/join_test.exs`, `grasp/test/grasp/index/templates_test.exs` (if it exists; otherwise cover Templates through `builder_test.exs` in Task 2).

**Interfaces (produced):**

```elixir
# Grasp.Index.Heex
@type interpolation :: %{line: pos_integer(), column: pos_integer(), text: String.t()}
@spec interpolations(String.t(), {pos_integer(), non_neg_integer()}) :: [interpolation()]
@spec interpolations(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [interpolation()]
# Same position arguments as tag_sites/2,3. Yields, in document order, the body of every
# top-level `{…}` (tag body or attribute value: everything between the braces, brace depth
# counted as skip_braces does today) and of every `<%= … %>`, `<% … %>` expression tag
# (everything between the delimiters; `<%!-- --%>` stays a comment and is skipped; `<%# … %>`
# is yielded and later fails to parse into anything, which is fine). `line`/`column` are the
# FILE position of the body's first character. `text` is the body with each continuation line
# prefixed by `indent` spaces, so parsing `text` at {line, column} gives file coordinates on
# every line (a heredoc's stripped indentation is exactly what those spaces put back).
# Comments, <script>/<style> bodies and slot/tag names are never inside a yielded body.
# The scan must be a single pass shared with tag_sites (refactor scan/3 to collect both kinds
# into one list and have tag_sites/interpolations filter it) — two passes that could drift
# is not acceptable.

# Grasp.Index.Extract
@type callee :: %{module: String.t() | nil, name: atom(), arity: non_neg_integer()}
@type call_site :: %{line, column, range, template: String.t() | nil, callee: callee() | nil}
# `callee` is the call as written: `module` is the literal alias receiver joined with "."
# (`"Greeter"`, `"SampleApp.Greeter"`), `nil` for a local/imported call and for a receiver that
# is an expression (`mod.f(x)`, `@mod.f(x)`); `name` the function; `arity` the argument count
# (for a capture `&Mod.f/2` the written arity). Every site add_site/2 builds gets a callee;
# the component-tag sites Heex builds carry `callee: nil` and are never matched by name.

@spec expression_sites(String.t(), pos_integer(), pos_integer()) :: [call_site()]
# Parses `text` with `Sourceror.parse_string(text, line: line, column: column)`; on
# {:error, _} retries with `text <> "\nend"`; on a second error returns []. Walks the AST with
# the same prewalk clauses call_sites/1 uses (extract that walk into a private function both
# call). A site's range comes from call_range/1 as today (callee only, alias receiver included).

@spec template_sites(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [call_site()]
# Heex.tag_sites(...) ++ (Heex.interpolations(...) |> Enum.flat_map(&expression_sites(&1.text, &1.line, &1.column)))
# sorted by {line, column}, uniq by {line, column}. Used by the ~H heredoc branch (replacing the
# direct Heex.tag_sites call), by the single-line ~H branch (keys at {line + 1, 0} zipped with
# ranges at {line, 0, column + 3} exactly as inline_tag_sites does — both lists come from the
# same function so they zip), and by Grasp.Index.Templates for a `.heex` file.

# Grasp.Index.Join — build/4, the `event.column == nil` branch becomes:
#   cond do
#     delegate_range -> visible call over delegate_range           (unchanged)
#     site = named_site(remaining, event) -> visible call over site.range, site claimed
#     not MapSet.member?(indexed, target) -> dropped                (unchanged)
#     event.line in span -> hidden call                             (unchanged)
#     true -> dropped
#   end
# named_site/2: among the definition's call_sites with a non-nil callee, not yet claimed, on
# event.line, with callee.name == name and callee.arity == arity, and
# (callee.module == nil or inspect(module) == callee.module or String.ends_with?(inspect(module), "." <> callee.module)),
# the first in document order ({line, column}). The claimed set lives in the reduce
# accumulator ({calls, hidden, claimed}). The visible call's kind is event.kind.
```

**Requirements:**

- **Heex.** `interpolations/2,3` as specified. `tag_sites/2,3` keeps its exact current output (every existing heex test passes untouched). A `{` inside an expression tag (`<%= %{a: 1} %>`) belongs to the expression tag, not to a `{…}` interpolation: the scan enters `<%` before it sees `{`. Unterminated bodies (`{` with no `}`, `<%` with no `%>`) yield nothing for that body, as the tag scan already tolerates. Update the `@moduledoc`: interpolation is no longer merely "skipped"; the module yields its body for the extractor to parse, and the counting caveat (a brace inside a string) still applies.
- **Extract.** `callee` on every site from `add_site/2`; `expression_sites/3`; `template_sites/3`; the two `~H` branches and `call_sites/1`'s walk refactored to share one prewalk. `@moduledoc` gains a paragraph on interpolations (what is parsed, the `end` retry, why callee is recorded) and the `~H` paragraph is updated. The `call_site` type documents `callee`.
- **Templates.** `definition/4` uses `Extract.template_sites(source, {1, 0}, nil)` for a `.heex` file; `.eex` stays `[]`. `@moduledoc` sentence "Only a `.heex` template carries call sites" is still true; extend it to say both tags and interpolations.
- **Join.** The `named_site` step as specified; `@moduledoc` rule list: the **Column-less events** rule states that a site the extractor parsed out of an interpolation with the same name, arity and (when written) module suffix on that line claims the event first, and only then the hidden-call rule applies. `@type call` unchanged.
- **Tests** (write them first, watch them fail, then implement):
  - `heex_test.exs`: `interpolations("<p>{Greeter.greet(@name)}</p>", {1, 0})` → `[%{line: 1, column: 5, text: "Greeter.greet(@name)"}]`; an attribute value `<a class={cls(@x)} href="/">` → column of `c` in `cls`; an expression tag `<%= if ok?(@u) do %>` on line 2 of a text with indent 4 → `%{line: 2, column: 8, text: " if ok?(@u) do "}` (body includes the surrounding spaces; column is the file column of the first body character, i.e. the space after `<%=`: with indent 4 the `<` is at 5, `%` 6, `=` 7, body starts at 8); a body spanning lines `{f(\n  @x)}` with indent 4 → text `"f(\n      @x)"` (2 written spaces + 4 indent); `<%!-- {x} --%>` and `<script>{x}</script>` yield nothing; `{"{"}` swallows to the end and yields nothing (documented caveat); `{a}{b}` on one line yields two bodies with columns 2 and 5.
  - `extract_test.exs`: `expression_sites("SampleApp.Greeter.greet(@name)", 12, 8)` → one site `line: 12, column: 26` (compiler position of `greet`: `SampleApp.Greeter.` is 18 chars, so 8 + 18 = 26), `range: %{start: {12, 8}, end: {12, 31}}`, `callee: %{module: "SampleApp.Greeter", name: :greet, arity: 1}`; `expression_sites(" if ok?(@u) do ", 3, 8)` → site for `ok?/1` with `callee.module == nil` at column 12; `expression_sites(" else ", 1, 1)` → `[]`; `expression_sites(" end ", 1, 1)` → `[]`; `expression_sites("@name", 1, 1)` → `[]` (the `@` node yields no site: confirm `:@` is handled as it is in clause bodies today — if `@` currently produces a site in clause bodies, keep that behaviour and assert what it produces instead); a heredoc `~H"""` body containing `<p>{SampleApp.Greeter.greet(@name)}</p>` inside a `def render(assigns)` at file indent 4 yields a call site keyed at the file line of that `<p>` line with column of `greet`, range from `S` to the end of `greet`, and callee module `"SampleApp.Greeter"`; a single-line `~H"<p>{shout(@x)}</p>"` on line 5 yields a site keyed at line 6 (compiler's key) whose range is on line 5 (file), like the tag test beside it; every existing extract test passes with `callee` added (update pinned maps to include `callee`, computing the written values).
  - `join_test.exs`: given a definition whose `call_sites` include `%{line: 6, column: 26, range: R, template: nil, callee: %{module: "Greeter", name: :greet, arity: 1}}` and an event `%{function: ..., line: 6, column: nil, target: {SampleApp.Greeter, :greet, 1}, kind: :remote}` → `calls` contains `%{target: "SampleApp.Greeter.greet/1", kind: :remote, range: R}` and `hidden_calls == []`; the same event with target `{Other.Greeter, :greet, 1}` → matches too (suffix rule: `Other.Greeter` ends with `.Greeter`); with target `{Greeting, :greet, 1}` → does not match (falls to the existing hidden/drop rules); callee `module: nil` matches any target module; two identical events on one line with two sites → two calls with the two ranges, in document order; a site with `callee: nil` is never matched by name; the existing column-less tests (lines ~120 and ~220) still pass unchanged.
- Gates; commit `Calls written inside templates are call sites` with the trailer.

### Task 2: The sample app exercises it, the viewer shows it, the docs say it

**Files:** modify `grasp/test/fixtures/sample_app/lib/sample_app_web/greet_html/show.html.heex` (append only), `grasp/test/fixtures/sample_app/lib/sample_app_web/greet_html.ex`, regenerate `grasp/test/fixtures/index.json`; tests `grasp/test/grasp/index/builder_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`; docs `grasp/guides/indexing.md`, `grasp/guides/reviewing.md` (only if its "Also calls" sentence now misdescribes templates), `README.md` / `grasp/README.md` (only if they describe template calls as hidden — grep first).

**Requirements:**

- **Sample app.** In `greet_html.ex`, add `alias SampleApp.Greeter` directly after `use Phoenix.Component` (this shifts `badge/1` down by one line: update every test that pins `badge/1`'s span or the `embed_templates` line — search for `badge` and `greet_html.ex` in `grasp/test` and fix the numbers). Append to `show.html.heex` after line 4, exactly:

  ```heex
  <%= if Greeter.greet(@name) do %>
    <span class={Greeter.greet(@name)}>{Greeter.greet(@name)}</span>
  <% end %>
  ```

  This covers an expression tag (column-bearing event), an attribute interpolation and a body interpolation on one line (two column-less events of the same name and arity on one line, handed out in document order), and the alias-written module (`Greeter`, resolved by the compiler to `SampleApp.Greeter`).
- **Regenerate the fixture.** From `grasp/test/fixtures/sample_app`: `mix deps.get` if needed (deps are vendored; never touch the network if it is already fetched), `mix grasp.index --out /tmp/grasp-fixture-index.json`; then from `grasp/`: `mix run test/fixtures/regenerate.exs /tmp/grasp-fixture-index.json`. Inspect the diff of `grasp/test/fixtures/index.json`: the three template-holding records (`SampleAppWeb.GreetHTML.show/1`, `SampleAppWeb.HelloLive.render/1`, `SampleAppWeb.GreetingComponent.render/1`) must now list `SampleApp.Greeter.greet/1` under `calls` with ranges (show/1: line 4 range `{4,5}..{4,28}`, plus lines 5, 6 (two ranges) from the appended block) and no longer under `hidden_calls`; nothing else about `greet/2`, `shout/1` or the git block may change. If the regenerated document differs in unrelated records, stop and report rather than committing it.
- **builder_test.exs.** Assert on the fresh index: `SampleAppWeb.GreetHTML.show/1` has a call with target `SampleApp.Greeter.greet/1` and range `%{"start" => [4, 5], "end" => [4, 28]}`, a call with kind `"remote"` on line 5 (the expression tag) and two calls on line 6 with distinct ranges; `hidden_calls` of that record contains no `SampleApp.Greeter.greet/1`; `SampleAppWeb.HelloLive.render/1` has the call on line 12 with range `[12, 8]..[12, 31]` and `SampleAppWeb.GreetingComponent.render/1` on line 9 with range `[9, 11]..[9, 34]`; `Grasp.Index.callers(index, "SampleApp.Greeter.greet/2")` still includes both render/1 records and `show/1` (update the pinned list if it changed shape). Run with `--include integration`.
- **review_live_test.exs.** Open the `SampleAppWeb.GreetHTML.show/1` card (there is an existing helper/test for opening the template record — reuse it) and assert the rendered card contains a clickable call element for target `SampleApp.Greeter.greet/1` on line 4 (find how component-tag calls render — a `phx-click="open_call"` element with `phx-value-target` — and assert the same shape for the interpolated call); click it and assert a card for `SampleApp.Greeter.greet/2` (the reader resolves arity 1 to the definition with arities [1, 2]) appears. Same for the `SampleAppWeb.HelloLive.render/1` card: its `{SampleApp.Greeter.greet(@name)}` on line 12 is clickable. Assert the "Also calls" footer of `show/1` no longer lists `SampleApp.Greeter.greet/1` (find the footer's current markup in `card_components.ex`; if the footer is not rendered when `hidden_calls` is empty, assert its absence).
- **Docs.** `grasp/guides/indexing.md`: line ~21 ("hidden call … Also calls") stays true in general; the Known-gaps-style bullet at ~107 ("Interpolated calls in templates stay hidden") is replaced by a sentence in the templates part saying interpolations and expression tags are parsed and their calls are clickable, placed by name where the compiler reports no column, with the two caveats (a body that is not a complete expression yields nothing; two identical calls on one line are placed in document order). Check `grasp/guides/reviewing.md:66` and both READMEs with `grep -n -i "hidden\|interpolat\|Also calls"` and fix any sentence that says template calls are hidden. Nothing about history.
- Gates (including `mix test --include integration`); commit `The sample app and the viewer show interpolated calls` with the trailer.
