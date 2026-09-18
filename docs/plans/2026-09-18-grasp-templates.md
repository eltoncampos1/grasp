# Grasp Templates as Code Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HEEx becomes code the graph knows: a function component tag inside an inline `~H` body or a `.heex` template file is a clickable call like any function call; every `.heex` file `embed_templates` compiles becomes a record of its own (`PageHTML.home/1`, source = the template, highlighted as HEEx); and a controller's `render(conn, :home, …)` reaches that template, so a route leads to its page and the page to its components.

**Architecture:** The compiler tracer already reports a component tag as a call to the component function with the tag's line and the column of the function name — inside `~H` and inside `.heex` files alike (there the event's file is the template and the caller is the function `embed_templates` generated). What the indexer lacks is a call site at that position: `Grasp.Index.Heex.tag_sites/2` scans template text for component tags and yields `{line, column, range}` sites in file coordinates; `Extract` adds them for every `~H` sigil in a body and records `embed_templates` patterns per module; `Builder` globs those patterns into template definitions (kind `:template`) and `Join` matches the events as it does for any call. A `render/2,3` call in a `*Controller` module whose second argument names a template that exists as a record is retargeted to that template. The viewer highlights a `.heex` record with Lumis's HEEx grammar and labels the kind.

**Tech Stack:** Elixir, Sourceror, the Elixir compiler tracer, Lumis (heex grammar), Phoenix LiveView.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 §Pipeline (step 2 and 3 additions: template sites, template definitions, render retargeting), §Index JSON (`kind: "template"`), §Known gaps (milestone 1 and 3 paragraphs about `~H`/`.heex` revised), Part 2 §Highlighting (HEEx grammar), §Milestones (6.1).

## Global Constraints

- Public repo: fixture names stay within `SampleApp`/`acme`; `@moduledoc`/`@doc`/`@spec` on everything public; comments state durable facts, never history. Tests never depend on the network.
- `grasp_index` gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test --include integration` (the integration test compiles `test/fixtures/sample_app`). `grasp` gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test`. Never `git add -A`; add files by path. Trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- The viewer fixture `grasp/test/fixtures/index.json` is regenerated from the sample app in Task 3; many viewer tests pin facts of it (`SampleApp.Greeter.greet/2` spans lines 6..11 of `lib/sample_app/greeter.ex`, `SampleApp.Formatter.shout/1` spans 8..10 with a 3-line `base_source`, `git.head` is `"0000000"`, `project.root` is `/tmp/sample_app`). Tasks 1–2 must not touch `greeter.ex` or `formatter.ex` in the fixture app.

---

### Task 1: Component tag sites in templates, and what a module embeds

**Files:** create `grasp_index/lib/grasp/index/heex.ex`, `grasp_index/test/grasp/index/heex_test.exs`; modify `grasp_index/lib/grasp/index/extract.ex`, `grasp_index/test/grasp/index/extract_test.exs`.

**Interfaces (produced):**

```elixir
# Grasp.Index.Heex
@type site :: Grasp.Index.Extract.call_site()   # %{line, column, range}
@spec tag_sites(String.t(), {pos_integer(), non_neg_integer()}) :: [site()]
#   Scans template text for component tags: `<.name` (local or imported component) and
#   `<Alias.Path.name` (remote). `name` is an Elixir function name (lowercase or underscore start, then
#   word characters, optional ? or !). Slot tags `<:name` are not components and are skipped; so is
#   anything inside `<%!-- --%>` and `<!-- -->` comments and inside `{ }` interpolation braces.
#   The second argument is {first_line, indent}: line 1 of the text is file line `first_line`, and every
#   line of the text sits `indent` columns to the right of column 1 in the file (heredoc indentation the
#   compiler stripped). For a text whose first line starts mid-line (a single-line ~H"..."), pass the
#   indent for that first line through a third form: tag_sites(text, {first_line, indent}, first_line_col)
#   where first_line_col is the file column of the text's first character (subsequent lines use indent).
#   Returned `column` is the file column of the function name's first character — the compiler reports the
#   event there. `range` covers from the character after `<` to the end of the name: `.name` or `Alias.Path.name`.

# Grasp.Index.Extract
@type call_site :: %{line: pos_integer(), column: pos_integer(), range: range(), template: String.t() | nil}
#   `template` is set only on a call site whose call is `render(_, :name_or_string, …)` or `render(_, :name)`
#   — the second argument is a literal atom or string — as the template name with any ".html" suffix
#   removed; nil otherwise. (Existing sites gain template: nil.)
# definitions' call_sites now also hold the tag sites of every ~H sigil in the definition body, with
#   template: nil, computed via Heex.tag_sites/2 from the sigil's string content and position (heredoc
#   ~H""" : first_line = sigil line + 1, indent = the heredoc's `indentation` metadata; single-line ~H"..."
#   : first_line = sigil line, first char at sigil column + 3).
@type embed :: %{module: String.t(), pattern: String.t(), file: String.t(), line: pos_integer()}
# extract/2 returns %{definitions, modules, embeds} — embeds are every `embed_templates "pattern"` or
#   `embed_templates "pattern", opts` call in a module body (not inside a def), pattern as written, file the
#   module's file, module the enclosing module name.
```

**Requirements:**

- **Scanner.** A single pass over the text tracking line and column (tabs count as one column, as the compiler does), skipping comments and `{…}` (brace depth, strings inside braces need not be handled beyond a simple depth count — say so in the moduledoc). A tag opener is `<` immediately followed by `.` and a name, or by an alias path (`[A-Z]\w*(\.[A-Z]\w*)*`) then `.` then a name. Verify the column rule against the compiler with the probe the plan owner ran: `<SampleAppWeb.GreetingComponent.render name="x" />` at file column 3 for `<` reported the event at column 35 = column of `render`. For a local `<.badge>` the plan owner did not measure; write a throwaway probe (a module compiled with `Code.compile_string` under a tracer printing `meta[:column]`, in `test/fixtures/sample_app` with `mix run --no-start`) and put the measured column in the report; if it is the column of `.` rather than of `badge`, make `tag_sites/2` return that for local tags and document it.
- **Extract.** Walk each definition body for `{:sigil_H, meta, [{:<<>>, str_meta, [content]} , _mods]}` nodes (content is a plain binary; a sigil with interpolation parts — impossible for `~H`, which is uppercase and does not interpolate — is skipped anyway). Read `meta[:line]`, `meta[:column]`, `str_meta[:indentation]` (verify the key Sourceror exposes for heredocs; if absent, compute the indent as the column of the closing `"""` line from `meta[:closing]` or from the source text), and `str_meta[:delimiter]` to distinguish heredoc from single-line. Append the tag sites to the definition's `call_sites`. The `render` template argument: when a call node's name is `render` and its second argument is a literal atom or binary, set `template` on that site. Module-body `embed_templates` calls are collected into `embeds`.
- **Tests.** `heex_test.exs`: a heredoc-shaped text with `<.badge label="x" />` on line 2 col 7 (indent 4 → file column of `badge` computed accordingly), `<SampleAppWeb.GreetingComponent.render />`, a slot `<:inner>`, a comment `<%!-- <.hidden /> --%>`, an interpolation `{if @x, do: "<.nope />"}` — asserting exact `{line, column, range}` triples and that the last three yield nothing; a single-line form. `extract_test.exs`: a module with `def render(assigns) do ~H""" … """ end` yields the tag sites with file coordinates; `render(conn, :show, name: n)` yields `template: "show"`; `render(conn, "show.html", …)` yields `"show"`; `embed_templates "page_html/*"` yields one embed with the pattern.
- Gates in `grasp_index/`; commit `Component tags in templates are call sites`.

---

### Task 2: Template files become records, and render reaches them

**Files:** modify `grasp_index/lib/grasp/index/builder.ex`, `grasp_index/lib/grasp/index/join.ex`, `grasp_index/lib/grasp/index/extract.ex` (`kind` type gains `:template`), `grasp_index/lib/grasp/index/base_ref.ex` (template change detection), `grasp_index/lib/grasp/index.ex` if it filters by kind; fixture app: create `grasp_index/test/fixtures/sample_app/lib/sample_app_web/greet_html.ex` (`SampleAppWeb.GreetHTML`, `use Phoenix.Component`, `embed_templates "greet_html/*"`, and a local component `def badge(assigns)` rendering `<span>{@label}</span>`), `grasp_index/test/fixtures/sample_app/lib/sample_app_web/greet_html/show.html.heex` (uses `<.badge label="hi" />`, `<SampleAppWeb.GreetingComponent.render name={@name} />`, `<a href="/greet/bob">again</a>`, `<p>{SampleApp.Greeter.greet(@name)}</p>`), modify `greet_controller.ex` so `show/2` ends with `render(conn, :show, name: name)` (keep its other calls; do not touch greeter.ex/formatter.ex) and add `plug :put_view, html: SampleAppWeb.GreetHTML` or `use Phoenix.Controller, formats: [:html]` as the fixture's Phoenix version needs — check how the controller is defined today; modify `hello_live.ex` so `render/1` also renders `<SampleAppWeb.GreetingComponent.render name={@name} />` (a remote component call inside `~H`); tests `builder_test.exs`, `join_test.exs`, `base_ref_test.exs`.

**Interfaces (consumed):** Task 1's `Heex.tag_sites/2`, `Extract` `embeds` and `template` on call sites.

**Interfaces (produced):**

```elixir
# JSON: a function record with "kind" => "template" — file is the .heex path relative to the root,
#   span 1..last line, source the file text, calls/hidden_calls as for any record, module the embedding
#   module, name the template's function name, arity 1, arities [1].
# A call whose target was Phoenix.Controller.render/2 or /3 and whose site carries `template` resolving
#   to an indexed record "<HTMLModule>.<template>/1" is written with that record as its target and
#   "kind" => "template" (a new call kind alongside remote/local/imported…).
# Grasp.Index.Builder: template definitions — for each embed, Path.wildcard(pattern) relative to the
#   directory of the embedding module's file; each match "<name>.<format>.<engine>" (Phoenix's rule:
#   the function name is the basename up to its first dot) becomes a definition
#   %{module, name, arity: 1, arities: [1], kind: :template, file: relative path, start_line: 1,
#     end_line: line count, source: file text, call_sites: Heex.tag_sites(text, {1, 0}),
#     head_positions: [], head_ranges: []} unless a definition with that {module, name, 1} exists.
```

**Requirements:**

- **HTML module resolution for `render`.** In `Join`, for a site with `template` in a definition whose module ends in `Controller`: `html = String.replace_suffix(module, "Controller", "HTML")`; target id `"#{html}.#{template}/1"`; when that id is in `indexed`, the event for `Phoenix.Controller.render/N` at that site becomes a call to it with kind `:template`; otherwise the call stays as it is (external). Say in the Join moduledoc that this follows Phoenix 1.7's `use Phoenix.Controller, formats: [:html]` convention and that a `put_view` naming another module is not followed (Known gap).
- **Event join for templates.** Events whose caller MFA is a template definition's join by `{line, column}` exactly as for other definitions (the file in the event is the template's path — assert that in the integration test). A `{…}` interpolated call has no column and stays a hidden call, as in `~H` bodies today.
- **Base ref.** `Grasp.Index.BaseRef` compares definitions by MFA between the two sides; template definitions on the base side come from globbing the *base tree*: for each embed found on the base side (the base `.ex` files are already extracted), read `git show <base>:<path>` for each template path the pattern matches in the current tree plus each path git lists at the base (`git ls-tree -r --name-only <base> -- <dir>`), and build the same definition shape. Keep it simple and documented: a template `change` is `added`/`modified`/`unchanged`/`removed` by comparing whole-file text. If this proves too invasive for `base_ref.ex`'s current structure, restrict to: current-side template records get `change: "unchanged"` and `base_source: nil` and record the limitation as a Known gap in the report for the plan owner to spec — do not leave the base pipeline broken.
- **Fixture and integration test.** After the fixture app changes, the integration test asserts: a record `SampleAppWeb.GreetHTML.show/1` with `kind: "template"`, `file: "lib/sample_app_web/greet_html/show.html.heex"`, span from 1, source equal to the file; its `calls` include `SampleAppWeb.GreetHTML.badge/1` (kind local or imported as the compiler reports — assert the target only) and `SampleAppWeb.GreetingComponent.render/1` with ranges covering the tag names; its `hidden_calls` include `SampleApp.Greeter.greet/1`; `SampleAppWeb.GreetController.show/2` has a call with `kind: "template"` targeting `SampleAppWeb.GreetHTML.show/1`; `SampleAppWeb.HelloLive.render/1` has a visible call to `SampleAppWeb.GreetingComponent.render/1` with a range inside the `~H` body; `Grasp.Index.callers(index, "SampleAppWeb.GreetingComponent.render/1")` includes both. Unit tests in `join_test.exs` for the render retargeting (indexed vs not) and in `builder_test.exs` (or a new `templates_test.exs`) for the glob → definition shape with a `tmp_dir` mini tree.
- Gates (`mix test --include integration`); commit `Template files are records and render reaches them`.

---

### Task 3: The viewer reads templates

**Files:** modify `grasp/lib/grasp/highlight.ex` (language by file extension), `grasp/lib/grasp_web/components/card_components.ex` (kind label), `grasp/assets/css/app.css` (if `.badge--template`/kind styling is needed), `grasp/test/fixtures/index.json` (regenerated), tests `highlight_test.exs`, `review_live_test.exs` (or `card_components_test.exs`), README (§Layout or §Gestures: components in templates are clickable; templates are cards), spec Known gaps.

**Requirements:**

- **Highlight.** `line_trees/2` picks `language: "heex"` when the record's `file` ends with `.heex`, else `"elixir"`; verify Lumis's heex output has the same `pre > code > div` structure the parser expects (write a test highlighting a two-line HEEx snippet through the public `lines/2` on a synthetic record and asserting two `span.line`s with at least one highlighted token). The call-range wrapper already splits tokens at range boundaries; assert that a component tag range inside a `~H` heredoc string (which Lumis's elixir grammar may render as one string token or, through injection, as HEEx tokens — check which) becomes a clickable span: test with the regenerated fixture's `SampleAppWeb.HelloLive.render/1` — `lines/2` output contains a `phx-click="open_call"` span whose text is `SampleAppWeb.GreetingComponent.render`.
- **Card.** `card__kind` shows `template` for the new kind (the record's kind string already renders; make sure the CSS does not break on the unknown value and that the callers menu, the Changes sidebar grouping by module and the palette (search over ids) list template records — they should with no change; assert in a LiveView test that `SampleAppWeb.GreetHTML.show/1` opens from the palette and renders its HEEx source with a clickable `badge` component span, and that clicking it opens `SampleAppWeb.GreetHTML.badge/1`).
- **Fixture regeneration.** From `grasp_index/test/fixtures/sample_app`: `mix grasp.index --out /tmp/…/index.json` (no `--base`), then a small script (commit it as `grasp/test/fixtures/regenerate.exs` with a `@moduledoc`-style header comment stating what it preserves) that takes the fresh document and copies over from the old fixture: `project.root` (`/tmp/sample_app`), the `git` block, and every record's `change`/`base_source`/`removed` where the id exists in the old fixture (the old fixture carries hand-made PR-mode facts on `shout/1` and others). Run the whole grasp suite; fix any test that pinned a count now changed (record totals, module lists), keeping every span-dependent test untouched — if greeter.ex or formatter.ex spans moved, stop and report.
- README and spec: in the spec, revise the Known gaps paragraphs that say a `.heex` file does not reach the graph and that `~H` component calls are hidden (they are now records and visible calls); add a Known gaps (milestone 6.1) with: interpolated `{…}` calls in templates stay hidden (no column from the compiler); `put_view` to a module not named `<Prefix>HTML` is not followed; templates rendered by `Phoenix.Template.render/4` or `render_to_string` are not linked; template `change` detection as implemented in Task 2 (or its limitation).
- Gates; commit `The viewer reads templates`.
