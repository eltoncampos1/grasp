# Grasp Routes as Edges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A template that links to a page (`href`), submits a form (`action`), navigates (`navigate`/`patch`) or fires an htmx request (`hx-get`/`hx-post`/…) names a route, and a `~p` sigil anywhere names one too. Each becomes a call of kind `route` from the template (or function) to the controller action or LiveView the router maps it to: clickable, drawn as a dashed edge, and listed in the action's callers. The controller → template → link → next action chain reads on the canvas.

**Architecture:** The scanner (`Grasp.Index.Heex`) learns to read a tag's attributes and yields the route-named ones with their values and ranges; the extractor (`Grasp.Index.Extract`) turns them — and every `~p` sigil its AST walk meets — into **route sites** `%{verb, path: [segment], range}` carried on the definition beside `call_sites`. The join copies them onto the record untouched. Once the entry points are detected, a new `Grasp.Index.Routes.resolve/2` matches each site's verb and segments against the `route`/`live_route` entries — most specific match wins — and writes a call `%{target, kind: :route, range, route: %{verb, path}}` on the record; unresolved sites vanish. Builder and Incremental both run that pass. The viewer marks the span `data-kind="route"` with the route as `title`, and the canvas draws the edge dashed.

**Tech Stack:** Elixir, Sourceror, Phoenix Router route metadata (already in the entry points), Phoenix LiveView (viewer), esbuild (`mix assets.build`).

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 §Templates "Routes are edges", §Index JSON (route call), Part 2 §Card (route span and edge), §Known gaps (milestone 7.3), §Milestones (7.3).

## Global Constraints

- Public repo: fixture names stay within `SampleApp`/`acme`; never name any other project or a local filesystem path. `@moduledoc`/`@doc`/`@spec` on everything public; comments state durable facts, never history ("was", "now", "previously", "no longer", "per review" are forbidden in code and docs).
- Gates, run from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (Task 2 also `mix test --include integration` and `mix assets.build`, committing the refreshed `grasp/priv/static/assets/grasp.js|grasp.css`). Read each exit code; never chain a commit on a failed gate. Never `git add -A`; add files by path. Never stage `grasp/priv/static/assets/app.js` or `app.css` if they appear untracked (an external watcher writes them). Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Sample-app facts viewer tests pin and no task may move: `SampleApp.Greeter.greet/2` spans lines 6..11 of `lib/sample_app/greeter.ex`; `SampleApp.Formatter.shout/1` spans 8..10; do not edit `greeter.ex` or `formatter.ex`. In `greet_html/show.html.heex`, lines 1–7 stay exactly as they are (line 3 is `<a href="/greet/bob">again</a>`, which Task 2 relies on); new lines are appended after line 7 only. `hello_live.ex` and `greeting_component.ex` are not edited.
- Existing scanner facts that must hold: `Heex.tag_sites/3` and `Heex.interpolations/3` keep their current output on every existing test (attribute `{…}` bodies are still interpolations; raw `<script>`/`<style>` bodies are still skipped; comments skipped; an unterminated `<%` resumes two characters on).
- Entry points reach the builder sorted by `{rank, label, target}` (`Grasp.Index.EntryPoints.detect/2`), not in router declaration order; resolution therefore ranks matches by specificity as the spec says.

---

### Task 1: Route sites in the indexer, resolved against the router

**Files:** modify `grasp/lib/grasp/index/heex.ex`, `grasp/lib/grasp/index/extract.ex`, `grasp/lib/grasp/index/join.ex`, `grasp/lib/grasp/index/templates.ex`, `grasp/lib/grasp/index/builder.ex`, `grasp/lib/grasp/index/incremental.ex`; create `grasp/lib/grasp/index/routes.ex`; tests `grasp/test/grasp/index/heex_test.exs`, `extract_test.exs`, `join_test.exs`, `templates_test.exs`, create `grasp/test/grasp/index/routes_test.exs`, plus `incremental_test.exs` if one exists (one assertion that a route call survives an update).

**Interfaces (produced):**

```elixir
# Grasp.Index.Heex
@type attribute_value :: {:string, String.t()} | {:expr, interpolation()}
@type route_attribute :: %{
        tag: String.t(),                 # "a", "form", ".form", "MyAppWeb.Nav.link" — the name after `<`
        name: String.t(),                # one of @route_attributes
        method: String.t() | nil,        # the tag's `method` attribute when it is a string literal, uppercased
        value: attribute_value(),        # {:expr, body} carries the same shape interpolations/3 yields
        range: Grasp.Index.Extract.range()  # the value WITH its delimiters: from the opening `"`/`'`/`{` to one past the closing one
      }
@route_attributes ~w(href action navigate patch hx-get hx-post hx-put hx-patch hx-delete)
@spec route_attributes(String.t(), {pos_integer(), non_neg_integer()}) :: [route_attribute()]
@spec route_attributes(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [route_attribute()]
# Produced by the SAME single pass as tag_sites/interpolations (extend found/3's result tags with
# {:route_attribute, attr}). The scan gains an attribute mode: after `<` followed by a tag name
# ([A-Za-z.:][\w.:-]*; not `<%`, `<!`, `</`, and the raw <script>/<style> clauses keep precedence),
# read attributes until `>` or `/>`: whitespace; a name ([^\s=/>{}"']+); optional `=` and a value —
# `"…"` (no escapes), `'…'`, `{…}` (read_braces, body yielded as an interpolation exactly as today),
# or an unquoted run [^\s>]+ (treated as a string). A bare `{…}` with no name is a root attribute:
# yield its body as an interpolation and continue. Values carry their file range. At the tag's end,
# emit one route_attribute per attribute whose name is in @route_attributes, with `method` read from
# the same tag's literal `method` attribute (uppercased) or nil. A `<` met before `>` ends the tag
# (malformed) and the scan resumes at that `<`. After `>` the scan returns to its normal mode. Note
# `<%= … %>` never starts a tag (`<%` matches first). Tag names are NOT case-normalised.

# Grasp.Index.Extract
@type segment :: String.t() | :dynamic
@type route_site :: %{verb: String.t(), path: [segment()], range: range()}
# definition gains  route_sites: [route_site()]   (Templates fills it too; [] for .eex)
@spec route_sites(String.t(), pos_integer(), pos_integer()) :: [route_site()]      # ~p sigils in an expression body
@spec template_route_sites(String.t(), {pos_integer(), non_neg_integer()}, pos_integer() | nil) :: [route_site()]
#   from Heex.route_attributes/3 (+ ~p route sites in every interpolation body, minus those whose
#   range start lies inside a route attribute's range — the attribute's site wins, it knows the verb)
@spec path_segments(String.t() | [String.t() | term()]) :: [segment()] | nil
#   A literal: must start with "/", else nil; cut at the first "?" or "#"; split on "/", drop empty
#   segments ("/" → []). Sigil parts (the `<<>>` node's list: binaries and `{:"::", _, …}` interpolation
#   nodes): the pieces are concatenated with each interpolation as one :dynamic marker; a segment that
#   contains a marker is :dynamic as a whole; text from the first "?" or "#" in a literal piece onward
#   (interpolations included) is dropped; a path that does not start with "/" → nil.
# Verb rules (attribute): hx-<verb> → VERB; href/navigate/patch → "GET"; action → attr.method when
#   present, else "POST" when the tag starts with "." or an uppercase letter (a component form),
#   else "GET". Verb for a ~p met by the AST walk (clause body or interpolation): "GET".
# Range of a ~p route site: Sourceror.get_range/1 of the sigil node, converted to {line, column} tuples
#   (end exclusive, as every range in this codebase).
# The AST walk: in collect_sites/1's prewalk, a `{:sigil_p, meta, [{:<<>>, _, parts}, _mods]}` node adds
#   a route site (it still adds no call site). Return shape: collect_sites/1 must now hand back both lists —
#   refactor so the definition builder receives %{call_sites, route_sites}; call_sites/1 keeps returning
#   only call sites for its existing callers if any remain.

# Grasp.Index.Join
# function_record gains route_sites: [Extract.route_site()], copied from the definition.
# @type call gains an optional key  route: %{verb: String.t(), path: String.t()}  (present only for kind :route)

# Grasp.Index.Routes  (new module)
@spec resolve([Join.function_record()], [map()]) :: [map()]
# `entries` are entry points in their JSON shape (Builder.entry_point_json/1 output or the document's
# list): maps with "kind" in ["route", "live_route"], "target", "meta" => %{"verb", "path"}. Every other
# entry is ignored. For each record: each route site is matched against the entries whose "verb" equals
# the site's verb, by segments (route path split on "/" dropping empties): a route segment starting with
# ":" matches any one site segment; one starting with "*" matches all remaining site segments (zero or
# more) and must be last; a literal route segment matches an equal literal site segment or a :dynamic
# one; lengths must otherwise agree. Among matches take the one with the fewest dynamic route segments,
# a glob counting as 2 and a param as 1; ties → the first in `entries` order. The winner becomes
# %{target: entry["target"], kind: :route, range: site.range, route: %{verb: entry verb, path: entry path}}
# appended to `calls` (then uniq + the existing sort); no match → nothing. The returned records have no
# :route_sites key. Records with no route sites pass through unchanged.

# Grasp.Index.Builder
# run/1: detected → entries = Enum.map(detected.entry_points, &entry_point_json/1) → records =
#   Routes.resolve(records, entries) → document(records, …, detected, …) (entry_point_json is applied once;
#   document/5 may take the json list or keep converting — do not convert twice). function_json/1 writes
#   "route" => %{"verb" => v, "path" => p} on a call that has :route, nothing on the others.
# Grasp.Index.Incremental
# update/5: detect entry points as today, then Routes.resolve(records, entry_points_json) before the
#   records are turned into JSON (the `functions` list used for detection can be built from ids of
#   kept ++ records without the final JSON — restructure minimally).
```

**Requirements:**

- **Heex.** Attribute mode as specified; every existing heex test passes unchanged. New tests: `route_attributes(~S|<a href="/greet/bob">again</a>|, {1, 0})` → `[%{tag: "a", name: "href", method: nil, value: {:string, "/greet/bob"}, range: %{start: {1, 9}, end: {1, 21}}}]`; `~S|<.form for={@f} action={~p"/greet"} method="put">|` → one attribute `name: "action"`, `method: "PUT"`, `value: {:expr, %{line: 1, column: 25, text: ~S|~p"/greet"|}}`, range `{1, 24}..{1, 35}`; `~S|<button hx-post={~p"/greet"}>go</button>|` → `hx-post`; an attribute on line 2 of a text with indent 4 has file columns; `~S|<a href='/x' class={cls(@a)}>|` → the href attribute AND `interpolations/2` still yields `cls(@a)`; `~S|<div {@rest} href="/x">|` → the href (root attribute skipped); `~S|<a href="/x"|` unterminated → nothing; `~S|<a href="/x" <b>|` malformed → nothing for `a`, scan continues; a `<script src="/js">` yields nothing (raw); `<%= link("x", to: "/y") %>` yields nothing (not a tag). `@moduledoc`: a paragraph on attribute reading and what a route attribute carries.
- **Extract.** As specified. Tests: `route_sites(~S|~p"/greet/#{@name}?x=1"|, 1, 1)` → `[%{verb: "GET", path: ["greet", :dynamic], range: %{start: {1, 1}, end: {1, 25}}}]`; `~p"/"` → `path: []`; `~p"/a-#{x}/b"` → `["a-…" is :dynamic, "b"]` i.e. `[:dynamic, "b"]`; a heredoc `~H` containing `<a href="/greet/bob">` inside `def render(assigns)` at indent 4 → route site `%{verb: "GET", path: ["greet", "bob"], range: {L, 13}..{L, 25}}` where L is that line; `<button hx-post={~p"/greet"}>` → `"POST", ["greet"]`, exactly one site (the attribute's; the sigil is not counted twice); `<.form action={~p"/greet"}>` → `"POST"`; `<form action="/search">` → `"GET"`; `<form action="/x" method="post">` → `"POST"`; `<a href={@path}>` → `[]`; `<a href="https://example.com/">` → `[]`; `<a href="#top">` → `[]`; `<a href="/x?q=1#frag">` → `["x"]`; single-line `~H"<a href=\"/x\">"` on line 5 → range on line 5 at the sigil's own column + 3 offset (like tag ranges). Every existing extract test passes with `route_sites` added to definitions (update pinned maps).
- **Templates.** A `.heex` definition carries `route_sites: Extract.template_route_sites(source, {1, 0}, nil)`; `.eex` → `[]`. One test.
- **Join.** `route_sites` copied; one test. Moduledoc: one sentence that route sites pass through untouched and are resolved by `Grasp.Index.Routes` once the router's routes are known.
- **Routes.** As specified, with `@moduledoc` explaining why specificity replaces declaration order (the entry list is sorted) and the segment rules. Tests use a hand-written `entries` list mirroring the sample app (`GET /greet/:name` → `SampleAppWeb.GreetController.show/2`, `POST /greet` → `create/2`, `live_route` `GET /hello` → `SampleAppWeb.HelloLive.mount/3`) plus `GET /users/:id`, `GET /users/new`, `GET /files/*path`: `["greet", "bob"]` GET → show/2 with `route: %{verb: "GET", path: "/greet/:name"}`; `["greet", :dynamic]` GET → show/2; `["greet"]` POST → create/2; `["hello"]` GET → mount/3; `["users", "new"]` GET → the `/users/new` entry (specificity); `["users", "7"]` → `/users/:id`; `["files", "a", "b"]` and `["files"]` → the glob; `["greet"]` GET (no such verb+path) → dropped; a record with no route sites is returned unchanged and without a `:route_sites` key; two sites resolving to the same target keep both calls (different ranges); the result's `calls` are sorted like the join's.
- **Builder/Incremental.** Wiring as specified; `function_json` writes `"route"`. If an `incremental_test.exs` exists, one test that a document with a `route` entry and an updated template file ends up with the route call on the rebuilt record.
- Gates; commit `Routes written in templates and sigils are call sites the router resolves` with the trailer.

### Task 2: The sample app links its pages, the viewer draws the hop, the docs say so

**Files:** modify `grasp/test/fixtures/sample_app/lib/sample_app_web/{greet_html.ex,greet_controller.ex,router.ex}`, `greet_html/show.html.heex` (append only); regenerate `grasp/test/fixtures/index.json`; modify `grasp/lib/grasp/highlight.ex`, `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`, rebuild `grasp/priv/static/assets/grasp.js|grasp.css`; tests `grasp/test/grasp/index/builder_test.exs`, `grasp/test/grasp/highlight_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`, and whichever tests pin facts the fixture moves; docs `grasp/guides/indexing.md`, `grasp/guides/reviewing.md`, `README.md`, `grasp/README.md` (feature lists).

**Requirements:**

- **Sample app.** `greet_html.ex`: after `use Phoenix.Component` add `use Phoenix.VerifiedRoutes, endpoint: SampleAppWeb.Endpoint, router: SampleAppWeb.Router` (this shifts `badge/1` down one line again — update every pinned number, grep `badge` and `greet_html.ex` under `grasp/test`). `greet_controller.ex`: same `use Phoenix.VerifiedRoutes` line after `use Phoenix.Controller…`, and append after `create/2`:

  ```elixir
  @doc "Sends the reader back to a greeting."
  def again(conn, _params), do: redirect(conn, to: ~p"/greet/bob")
  ```

  `router.ex`: add `get("/again", GreetController, :again)` directly after the `post("/greet", …)` line. Append to `show.html.heex` after line 7, exactly:

  ```heex
  <button hx-post={~p"/greet"}>shout</button>
  <.link navigate={~p"/hello"}>live</.link>
  ```

  Compile the sample app first (`cd grasp/test/fixtures/sample_app && mix compile`) and fix anything `~p` verification warns about before indexing.
- **Regenerate the fixture** exactly as before (`mix grasp.index --out /tmp/grasp-fixture-index.json` in the sample app, then `mix run test/fixtures/regenerate.exs /tmp/grasp-fixture-index.json` from `grasp/`). Expected diff and nothing else: `SampleAppWeb.GreetHTML.show/1` gains three `route` calls — line 3 → `SampleAppWeb.GreetController.show/2` with `"route": {"verb": "GET", "path": "/greet/:name"}` and range `[3, 9]..[3, 21]`; line 8 → `create/2` with `POST /greet` over `{~p"/greet"}` (range `[8, 17]..[8, 29]`); line 9 → `SampleAppWeb.HelloLive.mount/3` with `GET /hello` over `{~p"/hello"}` — plus the `<.link` tag's own call to `Phoenix.Component.link/1`; a new record `SampleAppWeb.GreetController.again/2` with a `route` call to `show/2` over the sigil (`GET /greet/:name`) and a call to `Phoenix.Controller.redirect/2`; a new entry point `GET /again` → `again/2`; `badge/1` and the module line shifts. `project.root` stays `/tmp/sample_app`; the `git` block is untouched. If unrelated records move, stop and report.
- **builder_test.exs** (integration): assert the three route calls on `show/1` (target, kind `"route"`, `route` map, range), the `again/2` route call, that `Grasp.Index.callers(index, "SampleAppWeb.GreetController.show/2")` includes `SampleAppWeb.GreetHTML.show/1` and `SampleAppWeb.GreetController.again/2`, and that `callers(index, "SampleAppWeb.HelloLive.mount/3")` includes `show/1`. Update the pinned entry-point list for `GET /again`.
- **Viewer.** `Grasp.Highlight`: the ranges handed to `wrap_calls` carry the call's `kind` and `route`; a route call's span gets ` data-kind="route" title="GET /greet/:name"` (escape both), other calls get no `data-kind`. `app.css`: `.call[data-kind="route"] { border-bottom-style: dotted; }` and `.connectors .edge[data-kind="route"] { stroke-dasharray: 6 4; }` (tokens only, no new colours). `canvas.js` `drawConnectors`: copy `site.dataset.kind` onto the path as ` data-kind="…"` when present. Run `mix assets.build` and commit the rebuilt bundle. `highlight_test.exs`: pinned call-target lists for `show/1` gain the route targets; one assertion on the route span's attributes.
- **review_live_test.exs.** Open `SampleAppWeb.GreetHTML.show/1`; assert `#card-1 .line[data-line='3'] span.call[data-kind='route'][data-target='SampleAppWeb.GreetController.show/2'][title='GET /greet/:name']`; click it and assert a card for `show/2` appears; assert the `hx-post` span on line 8 targets `create/2` with title `POST /greet`; open `SampleAppWeb.GreetController.again/2` and assert its route span targets `show/2`. Assert the callers menu of `show/2` (reuse the existing open-caller helpers) lists the template.
- **Docs.** `grasp/guides/indexing.md` templates part: routes are edges — the attributes read, the verb rules, `~p` anywhere as GET, specificity, and the gaps (helpers/assigns not followed, inherited htmx attributes not read). `grasp/guides/reviewing.md`: a dashed edge is an HTTP hop, dotted underline on the span, hover shows the route. `README.md` and `grasp/README.md` feature lists: one line. Durable facts only.
- Gates including `--include integration`; commit `The sample app links its pages and the canvas draws the hop` with the trailer.
