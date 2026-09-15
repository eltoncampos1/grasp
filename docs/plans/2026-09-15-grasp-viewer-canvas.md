# Grasp Viewer Canvas (Milestone 2.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Denser, wider cards in a GitHub Light theme highlighted by Lumis, on a canvas the reviewer can pan, zoom and rearrange by dragging cards, with connector lines that follow.

**Architecture:** `Grasp.Highlight` swaps Makeup for Lumis: the `html_linked` output (one `div.l-line` per source line, flat or nested `span.l-*` runs) is parsed with LazyHTML into text runs with columns, and the existing range-splitting and call-wrapping stays. The theme stylesheet comes from `Lumis.Theme.build_css!/1` at compile time. The tree auto-layout stays; each card gains a per-card `{dx, dy}` offset stored in the session forest and rendered as CSS custom properties. A `Canvas` JS hook owns pan/zoom (a transform written into a `<style>` element it keeps in `document.head`, so LiveView patches never touch it), card dragging (pushes the final offset to the server), and an SVG connector overlay drawn from the cards' actual positions inside a `phx-update="ignore"` element.

**Tech Stack:** Lumis ~> 0.8 (precompiled NIF; tree-sitter), lazy_html (now a runtime dep), Phoenix LiveView 1.2, esbuild. Makeup and makeup_elixir are removed.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` Part 2 — "Layout" (tree layout, connectors), "Highlighting", "Assets". This plan amends the spec: highlighting is Lumis, theme GitHub Light, and the canvas is pannable/zoomable with per-card offsets (added to the spec in Task 5).

## Global Constraints

- Only LiveView-rendered attributes may appear on LiveView-rendered elements. Client-only state lives in a `<style>` element in `document.head` owned by the hook, or inside an element with `phx-update="ignore"`. A hook may set an inline style on a card *during* a drag only, and must clear it when the server render arrives.
- Colours only from `:root` tokens; the Lumis theme CSS is the one exception and is inlined verbatim. No hard-coded colours elsewhere.
- Card ids stay integers; offsets are integer pixels in unscaled (stage) coordinates.
- Every module `@moduledoc`; `@doc`+`@spec` on public non-component functions; HEEx `{}` interpolation, list classes; `style=` only to inject CSS custom properties from server values.
- `mix format` before committing; commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; no third-party project names in tracked files; tests `async: true` with per-test session names unless they touch global state.
- Run `mix` from `grasp/`.

---

## File structure

```
grasp/
  mix.exs                                   # + lumis, lazy_html (runtime); − makeup, makeup_elixir
  lib/grasp/highlight.ex                    # Lumis-backed pieces; same public API
  lib/grasp/session/forest.ex               # card.offset, move/3, reset_offsets/1
  lib/grasp/session.ex                      # move/3, reset_offsets/1
  lib/grasp_web/components/layouts.ex       # theme_css/0 from Lumis
  lib/grasp_web/components/layouts/root.html.heex
  lib/grasp_web/components/card_components.ex   # offset custom props, class "lumis" on body
  lib/grasp_web/live/review_live.ex         # stage/svg/toolbar markup, move_card, reset_layout, zoom events
  assets/js/hooks/canvas.js                 # pan, zoom, drag, connectors, focus-pan
  assets/js/hooks/keys.js                   # drop the focus handler (moved to canvas.js)
  assets/js/app.js                          # register Canvas
  assets/css/app.css                        # GitHub Light tokens, density, stage/toolbar, drop pseudo connectors
  test/grasp/highlight_test.exs             # l-* classes, nesting test
  test/grasp/session/forest_test.exs        # offsets
  test/grasp_web/live/review_live_test.exs  # move_card / reset_layout / stage markup
docs/specs/2026-09-15-grasp-design.md       # amendments
```

---

### Task 1: Lumis highlighting

**Files:**
- Modify: `grasp/mix.exs`, `grasp/lib/grasp/highlight.ex`, `grasp/lib/grasp_web/components/layouts.ex`, `grasp/lib/grasp_web/components/layouts/root.html.heex`, `grasp/lib/grasp_web/components/card_components.ex` (body class), `grasp/assets/css/app.css` (the `.card__body` background rule)
- Test: `grasp/test/grasp/highlight_test.exs`

**Interfaces:**
- Unchanged public API: `Grasp.Highlight.render(record, card_id:, open_targets:, external?:) :: Phoenix.HTML.safe()`; same `span.line[data-line] > span.ln` and `span.call[...]` contract. Token spans now carry Lumis classes (`l-module`, `l-function-call`, `l-string`, ...); unhighlighted text is emitted bare.
- `GraspWeb.Layouts.theme_css/0 :: String.t()` — the `github_light` stylesheet, scoped as Lumis emits it (`.lumis`, `.l-*`).

- [ ] **Step 1: Verify the facts the implementation rests on**

From `grasp/` after adding the dep (Step 3 shows the mix.exs change): `mix run -e 'IO.puts Lumis.highlight!("x = \"a #{1} b\"\n\n  y", formatter: {:html_linked, language: "elixir"})'` prints `<pre class="lumis"><code ...><div class="l-line" data-line="1">…</div>…` with one `div.l-line` per source line (blank lines included) and a trailing `\n` inside each div; string interpolation nests `span.l-string-special` inside `span.l-string`. `LazyHTML.from_fragment(html) |> LazyHTML.to_tree()` returns `[{"pre", attrs, [{"code", attrs, [{"div", [{"class","l-line"},{"data-line","1"}], children}, ...]}]}]` where children are strings and `{"span", [{"class", "l-…"}], children}` tuples. Record the exact shapes in the report if they differ, and adapt `pieces/2` accordingly.

- [ ] **Step 2: Update the tests**

In `grasp/test/grasp/highlight_test.exs`:
- replace the `span.nc` assertion with `assert LazyHTML.query(map, "span.l-module") |> LazyHTML.text() == "Enum"`;
- add a nesting test:

```elixir
  test "nested Lumis spans keep the innermost class and exact columns" do
    record = %{
      "id" => "S.f/1",
      "span" => %{"start_line" => 1, "end_line" => 1},
      "source" => ~S|def f(x), do: "a #{inspect(x)} b"|,
      "calls" => [%{"target" => "Kernel.inspect/1", "kind" => "imported", "range" => %{"start" => [1, 20], "end" => [1, 27]}}]
    }

    html = record |> Highlight.render(card_id: 1, open_targets: [], external?: fn _ -> false end) |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment()
    [call] = LazyHTML.query(html, "span.call[data-target='Kernel.inspect/1']") |> Enum.to_list()
    assert LazyHTML.text(call) == "inspect"
    assert LazyHTML.query(call, "span.l-function-call") |> LazyHTML.text() == "inspect"
    assert LazyHTML.query(html, "span.line[data-line='1']") |> LazyHTML.text() == ~S|1def f(x), do: "a #{inspect(x)} b"|
  end
```

(`inspect` starts at column 20: `def f(x), do: "a #{` is 19 characters, so the range is `[1, 20]`–`[1, 27]`.) Keep every other test as is; they assert text, ranges and attributes, not Makeup classes.

- [ ] **Step 3: Dependencies**

`grasp/mix.exs` deps: remove `{:makeup, ...}` and `{:makeup_elixir, ...}`; add `{:lumis, "~> 0.8"}`; change `{:lazy_html, ">= 0.1.0", only: :test}` to `{:lazy_html, ">= 0.1.0"}`. Run `mix deps.get` (Lumis downloads a precompiled NIF on first compile) and `mix deps.unlock --unused`.

- [ ] **Step 4: Rewrite the tokenisation in `Grasp.Highlight`**

Replace the Makeup imports and `pieces/2` with a Lumis-backed version; everything from `split_at_ranges/2` on stays as it is.

```elixir
  # Lumis renders one div.l-line per source line whose children are text runs and
  # (possibly nested) span.l-* runs. Each text run becomes a piece carrying the class of
  # its innermost span, so the range splitter downstream sees the same shape Makeup gave it.
  defp pieces(source, first_line) do
    html = Lumis.highlight!(source, formatter: {:html_linked, language: "elixir"})

    lines =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("div.l-line")
      |> Enum.map(&LazyHTML.to_tree/1)

    lines
    |> Enum.with_index(first_line)
    |> Enum.flat_map(fn {[{"div", _attrs, children}], line} ->
      {pieces, _col} = Enum.reduce(children, {[], 1}, &runs(&1, nil, line, &2))
      Enum.reverse(pieces)
    end)
  end

  defp runs(text, css, line, {acc, col}) when is_binary(text) do
    text = String.replace_suffix(text, "\n", "")
    if text == "", do: {acc, col}, else: {[%{line: line, col: col, text: text, css: css} | acc], col + String.length(text)}
  end

  defp runs({"span", attrs, children}, _outer_css, line, acc) do
    css = attrs |> List.keyfind("class", 0, {"class", nil}) |> elem(1)
    Enum.reduce(children, acc, &runs(&1, css, line, &2))
  end

  defp runs(_other, _css, _line, acc), do: acc
```

`render/2` calls `pieces(record["source"], first_line)`. The line count for the gutter stays derived from the source (`String.split(source, "\n")`); if Lumis emits fewer `div.l-line`s than source lines (verify in Step 1 — it should not), fall back to `Map.get(by_line, line, [])` as today. Update the moduledoc: Lumis, tree-sitter, nested spans, innermost class.

- [ ] **Step 5: Theme CSS and body class**

`grasp/lib/grasp_web/components/layouts.ex`: replace `@makeup_css` with `@theme_css Lumis.Theme.build_css!(Lumis.Theme.get("github_light"))` and `makeup_css/0` with `theme_css/0` (`@doc "The Lumis github_light stylesheet, scoped under .lumis / .l-*."`). `root.html.heex`: `{raw("<style>" <> theme_css() <> "</style>")}`. `card_components.ex`: `<pre class="card__body lumis">`. `app.css`: `.card .card__body { background: var(--code-bg); }` replacing the `!important` rule (the `--code-bg` token arrives in Task 2; for now add `--code-bg: #ffffff;` to `:root`).

- [ ] **Step 6: Run, format, commit**

`mix test` green (the fixture test against `SampleApp.Formatter.shout/1` must still pass — it pins the column base). `mix compile --warnings-as-errors` clean. `git grep -n -i makeup grasp/` returns nothing except `mix.lock` (which `deps.unlock --unused` cleaned) — if the lock still lists makeup, run `mix deps.clean makeup makeup_elixir --unlock`.

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Highlight with Lumis instead of Makeup

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: GitHub Light theme and denser cards

**Files:**
- Modify: `grasp/assets/css/app.css`

- [ ] **Step 1: Tokens**

Replace the `:root` block with the GitHub Light palette (values are GitHub's Primer light tokens):

```css
:root {
  color-scheme: light;
  --bg: #ffffff;
  --bg-raised: #ffffff;
  --bg-sunken: #f6f8fa;
  --code-bg: #ffffff;
  --border: #d0d7de;
  --fg: #1f2328;
  --fg-muted: #57606a;
  --accent: #0969da;
  --accent-soft: color-mix(in oklch, var(--accent) 14%, transparent);
  --focus: #9a6700;
  --danger: #cf222e;
  --backdrop: color-mix(in oklch, var(--fg) 35%, transparent);
  --shadow: 0 1px 3px color-mix(in oklch, var(--fg) 12%, transparent);
  --radius: 6px;
  --space-xs: 0.25rem;
  --space-s: 0.5rem;
  --space-m: 1rem;
  --space-l: 1.5rem;
  --card-width: 60rem;
  --sidebar-width: 18rem;
  --code-size: 0.8rem;
  --code-leading: 1.25;
  --mono: ui-monospace, "JetBrains Mono", Menlo, monospace;
  --sans: system-ui, sans-serif;
}
```

- [ ] **Step 2: Density and surfaces**

- `.card`: add `box-shadow: var(--shadow)`; font-size `var(--code-size)`.
- `.card__body`: `line-height: var(--code-leading)`; padding `var(--space-xs) 0`.
- `.line`: `padding-inline: var(--space-s)`; `.ln`: `margin-inline-end: var(--space-s)`.
- `.sidebar`: background `var(--bg-sunken)`; `.module:hover, .module--open`: background `color-mix(in oklch, var(--accent) 8%, transparent)`.
- `.palette`, `.card__callers ul`: add `box-shadow: var(--shadow)`.
- `.call`: border-bottom colour stays `var(--accent)`; `.call[data-open="true"]` background `var(--accent-soft)`.
- Everything else already reads tokens; scan the file for any literal colour (`grep -nE '#[0-9a-f]{3,6}|black|white' app.css` should only hit the `:root` block).

- [ ] **Step 3: Verify visually and commit**

`mix assets.build`; start `mix grasp.serve --index test/fixtures/index.json --port 4046 &`, `curl -s http://127.0.0.1:4046/assets/app.css | grep -c "color-scheme: light"` → 1, kill the server. Commit:

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "GitHub Light palette and denser, wider cards

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Card offsets in the session

**Files:**
- Modify: `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp_web/live/review_live.ex`, `grasp/lib/grasp_web/components/card_components.ex`
- Test: `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp/session_test.exs`, `grasp/test/grasp_web/live/review_live_test.exs`

**Interfaces:**
- `Forest` card gains `offset: {integer(), integer()}` (default `{0, 0}`); `Forest.move(t, id, {dx, dy}) :: t` (no-op on unknown id), `Forest.reset_offsets(t) :: t`.
- `Session.move(name, card_id, {dx, dy})`, `Session.reset_offsets(name)` → forest.
- LiveView events: `move_card` (`%{"card" => id, "dx" => int, "dy" => int}`, ints may arrive as numbers or numeric strings; anything else ignored), `reset_layout`.
- Card DOM: the `<article>` carries `style={"--dx: #{dx}px; --dy: #{dy}px"}` and `data-dx`/`data-dy`; CSS `.card { translate: var(--dx, 0px) var(--dy, 0px); }`.

- [ ] **Step 1: Tests**

Forest (`forest_test.exs`):

```elixir
  test "move/3 sets a card's offset and reset_offsets/1 clears every offset" do
    {forest, a} = Forest.open_root(Forest.new(), "A.f/1")
    {forest, b} = Forest.open_child(forest, a, "B.g/0")

    assert Forest.card(forest, a).offset == {0, 0}
    forest = Forest.move(forest, b, {40, -12})
    assert Forest.card(forest, b).offset == {40, -12}
    assert Forest.move(forest, 999, {1, 1}) == forest

    forest = Forest.reset_offsets(forest)
    assert Forest.card(forest, b).offset == {0, 0}
  end
```

Session (`session_test.exs`): `Session.move(name, root, {10, 20})` returns a forest whose card has that offset and broadcasts; `Session.reset_offsets(name)` clears it.

LiveView (`review_live_test.exs`):

```elixir
  test "dragging a card stores its offset and reset_layout clears it", %{view: view, name: name} do
    Session.open_root(name, @greet)

    render_hook(view, "move_card", %{"card" => 1, "dx" => 40, "dy" => -12})
    assert has_element?(view, "#card-1[data-dx='40'][data-dy='-12']")
    assert has_element?(view, "#card-1[style*='--dx: 40px']")

    render_hook(view, "move_card", %{"card" => "1", "dx" => "7", "dy" => "8"})
    assert has_element?(view, "#card-1[data-dx='7'][data-dy='8']")

    render_hook(view, "move_card", %{"card" => 1, "dx" => "nope", "dy" => 0})
    assert has_element?(view, "#card-1[data-dx='7']")

    render_click(view, "reset_layout", %{})
    assert has_element?(view, "#card-1[data-dx='0'][data-dy='0']")
  end
```

- [ ] **Step 2: Implement**

`forest.ex`: add `offset: {0, 0}` to the card map in `add_card/4` and to the `card()` type; add

```elixir
  @doc "Sets a card's layout offset in stage pixels; no-op on an unknown id."
  @spec move(t(), id(), {integer(), integer()}) :: t()
  def move(%__MODULE__{} = forest, id, {dx, dy}) when is_integer(dx) and is_integer(dy) do
    case card(forest, id) do
      nil -> forest
      card -> %{forest | cards: Map.put(forest.cards, id, %{card | offset: {dx, dy}})}
    end
  end

  @doc "Clears every card's offset so the tree returns to its automatic layout."
  @spec reset_offsets(t()) :: t()
  def reset_offsets(%__MODULE__{} = forest) do
    %{forest | cards: Map.new(forest.cards, fn {id, card} -> {id, %{card | offset: {0, 0}}} end)}
  end
```

`session.ex`: `move/3` and `reset_offsets/1` delegating through `mutate/2`.

`review_live.ex`: events

```elixir
  def handle_event("move_card", %{"card" => card, "dx" => dx, "dy" => dy}, socket) do
    case {int(card), int(dx), int(dy)} do
      {id, dx, dy} when is_integer(id) and is_integer(dx) and is_integer(dy) -> mutate(socket, &Session.move(&1, id, {dx, dy}))
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reset_layout", _params, socket), do: mutate(socket, &Session.reset_offsets/1)
```

and `int/1` accepts integers as well as numeric strings (negative included: `Integer.parse("-12")`). Place both above the catch-all.

`card_components.ex`: on both `<article>`s add `style={"--dx: #{dx}px; --dy: #{dy}px"}` and `data-dx={dx}` `data-dy={dy}` with `{dx, dy} = @card.offset` (assign them in the component). `app.css`: `.card { translate: var(--dx, 0px) var(--dy, 0px); }`.

- [ ] **Step 3: Run, format, commit**

`mix test` green.

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Store per-card layout offsets in the session

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Canvas hook — pan, zoom, drag, connectors

**Files:**
- Create: `grasp/assets/js/hooks/canvas.js`
- Modify: `grasp/assets/js/hooks/keys.js` (remove the `focus` handler), `grasp/assets/js/app.js`, `grasp/lib/grasp_web/live/review_live.ex` (stage, svg, toolbar), `grasp/assets/css/app.css`
- Test: `grasp/test/grasp_web/live/review_live_test.exs` (markup)

**Interfaces:**
- Markup inside `<section class="canvas" id="canvas" phx-hook="Canvas">`: a toolbar `div.toolbar` with buttons `#zoom-in`, `#zoom-out`, `#zoom-fit` (client-only, `type="button"`, no `phx-click`) and `button#reset-layout[phx-click=reset_layout]`; `div#stage.stage` wrapping `<svg id="connectors" class="connectors" phx-update="ignore"></svg>` and the existing `div.roots`.
- Hook contract: pan/zoom state `{x, y, scale}` in the hook; transform written to `<style id="grasp-canvas-style">#stage{transform:translate(Xpx,Ypx) scale(S)}</style>` in `document.head`; drag threshold 4 px; on drop `pushEvent("move_card", {card, dx, dy})`; connectors redrawn on `updated()`, drag, resize; server `focus` push handled here (pan so the card is visible).

- [ ] **Step 1: Markup and tests**

In `ReviewLive.render/1` (non-empty clause) replace the `<section class="canvas" ...>` body with:

```heex
      <section class="canvas" id="canvas" phx-hook="Canvas">
        <div class="toolbar">
          <button type="button" id="zoom-out" title="Zoom out">−</button>
          <button type="button" id="zoom-fit" title="Fit all cards">fit</button>
          <button type="button" id="zoom-in" title="Zoom in">+</button>
          <button type="button" id="reset-layout" phx-click="reset_layout" title="Return cards to the automatic layout">reset layout</button>
        </div>
        <p :if={@forest.roots == []} class="empty">Pick a function from the sidebar or press <kbd>⌘K</kbd>.</p>
        <div id="stage" class="stage">
          <svg id="connectors" class="connectors" phx-update="ignore" aria-hidden="true"></svg>
          <div class="roots">
            <.card_node :for={root <- @forest.roots} forest={@forest} index={@index} card_id={root} editor={@editor} callers_open={@callers_open} />
          </div>
        </div>
      </section>
```

Test additions (`review_live_test.exs`): `assert has_element?(view, "#canvas[phx-hook='Canvas'] #stage svg#connectors[phx-update='ignore']")` and `assert has_element?(view, "#canvas .toolbar #reset-layout[phx-click='reset_layout']")`.

- [ ] **Step 2: The hook**

`grasp/assets/js/hooks/canvas.js`:

```js
const MIN_SCALE = 0.25
const MAX_SCALE = 2.5
const DRAG_THRESHOLD = 4

const Canvas = {
  mounted() {
    this.stage = this.el.querySelector("#stage")
    this.svg = this.el.querySelector("#connectors")
    this.view = {x: 24, y: 24, scale: 1}
    this.style = document.getElementById("grasp-canvas-style") || document.head.appendChild(Object.assign(document.createElement("style"), {id: "grasp-canvas-style"}))
    this.applyView()

    this.onWheel = (e) => this.wheel(e)
    this.onPointerDown = (e) => this.pointerDown(e)
    this.onPointerMove = (e) => this.pointerMove(e)
    this.onPointerUp = (e) => this.pointerUp(e)
    this.onClickCapture = (e) => { if (this.suppressClick) { e.stopPropagation(); e.preventDefault(); this.suppressClick = false } }
    this.el.addEventListener("wheel", this.onWheel, {passive: false})
    this.el.addEventListener("pointerdown", this.onPointerDown)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    this.el.addEventListener("click", this.onClickCapture, true)

    this.el.querySelector("#zoom-in").addEventListener("click", () => this.zoomBy(1.2))
    this.el.querySelector("#zoom-out").addEventListener("click", () => this.zoomBy(1 / 1.2))
    this.el.querySelector("#zoom-fit").addEventListener("click", () => this.fit())

    this.resizeObserver = new ResizeObserver(() => this.drawConnectors())
    this.resizeObserver.observe(this.stage)
    this.handleEvent("focus", ({id}) => this.revealCard(id))
    this.drawConnectors()
  },

  updated() {
    // The server has rendered the offsets; drop any inline translate left by a drag.
    this.el.querySelectorAll(".card[style*='translate']").forEach((card) => (card.style.translate = ""))
    this.drawConnectors()
  },

  destroyed() {
    this.el.removeEventListener("wheel", this.onWheel)
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    this.el.removeEventListener("click", this.onClickCapture, true)
    this.resizeObserver.disconnect()
    this.style.remove()
  },

  applyView() {
    const {x, y, scale} = this.view
    this.style.textContent = `#stage{transform:translate(${x}px,${y}px) scale(${scale})}`
  },

  wheel(e) {
    const body = e.target.closest(".card__body")
    if (body && !e.ctrlKey && !e.metaKey && Math.abs(e.deltaX) > Math.abs(e.deltaY) && body.scrollWidth > body.clientWidth) return
    e.preventDefault()
    if (e.ctrlKey || e.metaKey) {
      this.zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY)
    } else {
      this.view.x -= e.deltaX
      this.view.y -= e.deltaY
      this.applyView()
    }
  },

  zoomBy(factor) {
    const r = this.el.getBoundingClientRect()
    this.zoomAt(factor, r.left + r.width / 2, r.top + r.height / 2)
  },

  zoomAt(factor, clientX, clientY) {
    const r = this.el.getBoundingClientRect()
    const px = clientX - r.left
    const py = clientY - r.top
    const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, this.view.scale * factor))
    const k = next / this.view.scale
    this.view = {x: px - (px - this.view.x) * k, y: py - (py - this.view.y) * k, scale: next}
    this.applyView()
  },

  fit() {
    const cards = Array.from(this.el.querySelectorAll(".card"))
    if (cards.length === 0) return
    const box = this.stageBox(cards)
    const r = this.el.getBoundingClientRect()
    const scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, Math.min((r.width - 48) / box.width, (r.height - 48) / box.height, 1)))
    this.view = {x: 24 - box.left * scale, y: 24 - box.top * scale, scale}
    this.applyView()
  },

  // Bounding box of elements in unscaled stage coordinates.
  stageBox(elements) {
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
    for (const el of elements) {
      const b = el.getBoundingClientRect()
      left = Math.min(left, (b.left - s.left) / scale)
      top = Math.min(top, (b.top - s.top) / scale)
      right = Math.max(right, (b.right - s.left) / scale)
      bottom = Math.max(bottom, (b.bottom - s.top) / scale)
    }
    return {left, top, right, bottom, width: right - left, height: bottom - top}
  },

  revealCard(id) {
    if (id == null) return
    const card = document.getElementById(`card-${id}`)
    if (!card) return
    const r = this.el.getBoundingClientRect()
    const b = card.getBoundingClientRect()
    let dx = 0, dy = 0
    if (b.left < r.left) dx = r.left - b.left + 24
    else if (b.right > r.right) dx = Math.max(r.right - b.right - 24, r.left - b.left + 24)
    if (b.top < r.top) dy = r.top - b.top + 24
    else if (b.bottom > r.bottom) dy = Math.max(r.bottom - b.bottom - 24, r.top - b.top + 24)
    if (dx || dy) { this.view.x += dx; this.view.y += dy; this.applyView() }
  },

  pointerDown(e) {
    if (e.button !== 0) return
    const header = e.target.closest(".card__header")
    if (header && !e.target.closest("button, a")) {
      const card = header.closest(".card")
      this.drag = {kind: "card", card, id: card.id.replace("card-", ""), startX: e.clientX, startY: e.clientY,
                   dx: parseInt(card.dataset.dx || "0", 10), dy: parseInt(card.dataset.dy || "0", 10), moved: false}
    } else if (!e.target.closest(".card, .toolbar, button, a, input")) {
      this.drag = {kind: "pan", startX: e.clientX, startY: e.clientY, x: this.view.x, y: this.view.y, moved: false}
    }
  },

  pointerMove(e) {
    if (!this.drag) return
    const mx = e.clientX - this.drag.startX
    const my = e.clientY - this.drag.startY
    if (!this.drag.moved && Math.hypot(mx, my) < DRAG_THRESHOLD) return
    this.drag.moved = true
    if (this.drag.kind === "pan") {
      this.view.x = this.drag.x + mx
      this.view.y = this.drag.y + my
      this.applyView()
    } else {
      const {scale} = this.view
      this.drag.card.style.translate = `${this.drag.dx + mx / scale}px ${this.drag.dy + my / scale}px`
      this.drawConnectors()
    }
  },

  pointerUp(e) {
    if (!this.drag) return
    const drag = this.drag
    this.drag = null
    if (!drag.moved) return
    this.suppressClick = true
    if (drag.kind === "card") {
      const {scale} = this.view
      const dx = Math.round(drag.dx + (e.clientX - drag.startX) / scale)
      const dy = Math.round(drag.dy + (e.clientY - drag.startY) / scale)
      this.pushEvent("move_card", {card: drag.id, dx, dy})
    }
  },

  drawConnectors() {
    if (!this.svg) return
    const s = this.stage.getBoundingClientRect()
    const {scale} = this.view
    const paths = []
    for (const child of this.el.querySelectorAll(".node__children > .node > .card")) {
      const parent = child.closest(".node__children")?.previousElementSibling
      if (!parent || !parent.classList.contains("card")) continue
      const a = parent.getBoundingClientRect()
      const b = child.getBoundingClientRect()
      const x1 = (a.right - s.left) / scale
      const y1 = (a.top - s.top) / scale + 18
      const x2 = (b.left - s.left) / scale
      const y2 = (b.top - s.top) / scale + 18
      const mid = (x1 + x2) / 2
      paths.push(`<path d="M ${x1} ${y1} C ${mid} ${y1}, ${mid} ${y2}, ${x2} ${y2}" />`)
    }
    this.svg.setAttribute("width", String(this.stage.scrollWidth))
    this.svg.setAttribute("height", String(this.stage.scrollHeight))
    this.svg.innerHTML = paths.join("")
  },
}

export default Canvas
```

`keys.js`: remove the `this.handleEvent("focus", ...)` block (the Canvas hook owns it now). `app.js`: import and register `Canvas`.

- [ ] **Step 3: CSS**

- `.canvas { position: relative; overflow: hidden; padding: 0; cursor: grab; }` and `.canvas:active { cursor: grabbing; }`.
- `.stage { position: absolute; inset-block-start: 0; inset-inline-start: 0; transform-origin: 0 0; }` (no `transform` here — the hook's style tag sets it).
- `.connectors { position: absolute; inset: 0; overflow: visible; pointer-events: none; z-index: 0; }` and `.connectors path { fill: none; stroke: var(--border); stroke-width: 1.5; }`.
- `.roots { position: relative; z-index: 1; padding: var(--space-m); }`.
- `.toolbar { position: absolute; inset-block-start: var(--space-s); inset-inline-end: var(--space-s); z-index: 3; display: flex; gap: var(--space-xs); background: var(--bg-raised); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow); padding: var(--space-xs); }` and `.toolbar button { padding: 0 var(--space-s); color: var(--fg-muted); } .toolbar button:hover { color: var(--fg); }`.
- `.card__header { cursor: grab; }`; `.card` keeps `translate: var(--dx, 0px) var(--dy, 0px)` from Task 3.
- Remove the `.node__children::before` and `.node__children > .node > .card::before` pseudo-element connectors and the `position: relative` on `.node__children` if nothing else needs it.
- `.empty` inside the canvas: `position: absolute; inset-block-start: 40%; inset-inline: 0; text-align: center;`.

- [ ] **Step 4: Manual verification and commit**

`mix assets.build` clean; `mix test` green (markup tests). Start `mix grasp.serve --index test/fixtures/index.json --port 4046 &`; `curl -s http://127.0.0.1:4046/ | grep -c 'id="connectors"'` → 1 and `curl -s http://127.0.0.1:4046/assets/app.js | grep -c "grasp-canvas-style"` → 1; kill the server. Record in the report which behaviours could only be verified by reading (pointer events, wheel).

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Pan, zoom and drag cards on the canvas with SVG connectors

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Docs and a real-index run

**Files:**
- Modify: `docs/specs/2026-09-15-grasp-design.md`, `grasp/README.md`, root `README.md`

- [ ] **Step 1: Spec amendments**

In Part 2: "Layout" — add that the canvas pans (drag empty space or wheel), zooms (Ctrl/Cmd+wheel, toolbar), and that each card carries a persistent offset from its automatic position, set by dragging its header, stored in the session forest and cleared by "reset layout"; connectors are an SVG overlay drawn client-side from actual positions. "Highlighting" — Lumis (tree-sitter) `html_linked` output parsed into text runs, GitHub Light theme inlined from `Lumis.Theme.build_css!/1`; the Makeup sentence goes. "Assets" — lazy_html is a runtime dependency. Add to the Decisions list: "Highlighting by Lumis with the `github_light` theme; the whole UI uses the GitHub Light palette."

- [ ] **Step 2: READMEs**

`grasp/README.md`: mention pan/zoom/drag and the toolbar, and that the first `mix deps.get` downloads Lumis's precompiled NIF. Root `README.md`: adjust the one-paragraph description if it names Makeup or a dark theme.

- [ ] **Step 3: Real-index run**

Start the viewer against the real index the controller names (never write its name into tracked files), on a port other than 4040, `curl` the page and both assets (200), confirm the page contains `class="lumis"` bodies once a card is open is not curl-testable — instead confirm the theme CSS is inlined (`grep -c "github_light"` on `/` → 1). Kill the server.

- [ ] **Step 4: Commit**

```bash
cd ~/repos/grasp && git add -A && git commit -m "Document the Lumis theme and the pannable canvas

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Sidebar toggle (Cmd+M), zoom readout, Cmd+0, Space-pan and Ctrl-drag

**Files:**
- Modify: `grasp/lib/grasp_web/live/review_live.ex`, `grasp/assets/js/hooks/keys.js`, `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`
- Test: `grasp/test/grasp_web/live/review_live_test.exs`

**Interfaces:**
- Zoom readout: the toolbar gains `<span id="zoom-level" class="toolbar__zoom" phx-update="ignore">100%</span>` between `#zoom-out` and `#zoom-in`. The Canvas hook writes `Math.round(scale * 100) + "%"` into it from `applyView()` (the span is ignored by patches, so the hook owns its text). Clicking the readout resets to 100% (`resetZoom()`).
- `resetZoom()`: sets `scale` to 1 keeping the stage point under the canvas centre fixed (`zoomAt(1 / scale, centreX, centreY)`), then `applyView()`.
- Keys hook: `Cmd+0` / `Ctrl+0` → `preventDefault` and dispatch a `grasp:zoom-reset` CustomEvent on `window`; the Canvas hook listens for it and calls `resetZoom()` (hook-to-hook via a DOM event, no server round trip). `Cmd+=`/`Cmd+-` are left to the browser.
- Assign `sidebar_open?: true`; event `toggle_sidebar` (no params). `<main class={["app", !@sidebar_open? && "app--no-sidebar"]} data-sidebar={to_string(@sidebar_open?)}>`; the `<aside class="sidebar">` is rendered only when open (`:if={@sidebar_open?}`). A toolbar button `#toggle-sidebar[phx-click=toggle_sidebar]` (label `sidebar`, title "Show or hide the sidebar (⌘M)") sits first in the canvas toolbar.
- Keys hook: `Cmd+M` / `Ctrl+M` and `Cmd+\` / `Ctrl+\` push `toggle_sidebar` (with `preventDefault`). Note: on macOS, Cmd+M is the OS "minimise window" shortcut and browsers may act on it before the page sees the key; `Cmd+\` is the fallback that browsers pass through.

- [ ] **Step 1: Test**

```elixir
  test "the sidebar can be hidden and shown", %{view: view} do
    assert has_element?(view, "main.app[data-sidebar='true'] aside.sidebar")
    render_hook(view, "toggle_sidebar", %{})
    refute has_element?(view, "aside.sidebar")
    assert has_element?(view, "main.app.app--no-sidebar[data-sidebar='false']")
    view |> element("#toggle-sidebar") |> render_click()
    assert has_element?(view, "aside.sidebar")
  end
```

- [ ] **Step 2: Implement**

`review_live.ex`: add the assign in `mount/3`, the event

```elixir
  def handle_event("toggle_sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_open?, &(not &1))}
```

above the catch-all, the `main` class/data attribute, `:if={@sidebar_open?}` on the aside, and the toolbar button. `keys.js`: in the keydown handler, before the modifier bail-out, handle `(e.metaKey || e.ctrlKey) && (e.key === "m" || e.key === "\\")` → `preventDefault` + `pushEvent("toggle_sidebar", {})` (this must run even when the palette is open? No — keep it inside the existing "not typing, palette closed" guard). `app.css`: `.app--no-sidebar { grid-template-columns: 1fr; }`.

- [ ] **Step 2b: Zoom readout and Cmd+0**

`review_live.ex`: add the `#zoom-level` span to the toolbar as described (its initial text `100%`). `canvas.js`: in `mounted()` cache `this.zoomLevel = this.el.querySelector("#zoom-level")`; in `applyView()` set `this.zoomLevel.textContent = Math.round(this.view.scale * 100) + "%"`; add `resetZoom()`; in the capture-phase click delegation handle `#zoom-level` → `resetZoom()`; add `this.onZoomReset = () => this.resetZoom()` registered on `window` for `grasp:zoom-reset` and removed in `destroyed()`. `keys.js`: `(e.metaKey || e.ctrlKey) && e.key === "0"` → `preventDefault` + `window.dispatchEvent(new CustomEvent("grasp:zoom-reset"))`. CSS: `.toolbar__zoom { min-width: 3.5em; text-align: center; color: var(--fg-muted); cursor: pointer; font-variant-numeric: tabular-nums; }`. Test: `assert has_element?(view, "#canvas .toolbar #zoom-level[phx-update='ignore']", "100%")`.

- [ ] **Step 2c: Space-pan and Ctrl-drag**

Today a pointer-down on a card never pans, and dragging is header-only. Add to `canvas.js`:
- **Space held = pan anywhere.** Window `keydown`/`keyup` listeners track `this.spaceHeld` for `e.key === " "` when the target is not an input/textarea and the palette is closed; `keydown` calls `preventDefault()` (stops page scroll) and adds class `grasp-space` to `document.body` (body is not LiveView-rendered, so the class survives patches); `keyup` removes both. In `pointerDown`, when `this.spaceHeld` is true start a `pan` drag regardless of target (cards included) and `preventDefault()` so no text selection starts. CSS: `body.grasp-space .canvas, body.grasp-space .card { cursor: grab; }`.
- **Ctrl+press on a card = drag the card.** In `pointerDown`, when `e.ctrlKey` and `e.target.closest(".card")` exists (any part of the card, body included), start a `card` drag for that card and `preventDefault()` (no text selection). While a ctrl-initiated drag is active, suppress the context menu: a `contextmenu` listener on the canvas calls `preventDefault()` when `this.drag?.ctrl` or a ctrl-drag ended within the last 300 ms (`this.ctrlDragEndedAt`). Header drags keep working without modifiers.
- Remove all new listeners in `destroyed()`.

Document the gestures in `grasp/README.md` (Space+drag pans anywhere; Ctrl+drag moves a card from anywhere on it; header drag moves a card; Cmd/Ctrl+wheel zooms; Cmd+0 resets zoom; Cmd+M / Cmd+\\ toggles the sidebar).

- [ ] **Step 3: Verify, format, commit**

`mix test` green; `mix assets.build` clean.

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Toggle the sidebar with Cmd+M; zoom readout, Cmd+0, Space-pan and Ctrl-drag

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Crisp text while dragging and panning

**Files:**
- Modify: `grasp/assets/js/hooks/canvas.js`, `grasp/assets/css/app.css`

**Problem:** dragging a card (and panning) blurs the text even at 100% zoom. Two causes: the hook writes fractional translates during a drag (`${dx + mx / scale}px`) and pans (`translate(${x}px, ${y}px)` with fractional `x`/`y`), so composited text lands on subpixel offsets; and `.stage { will-change: transform }` forces a compositor layer that rasterises text once and shifts it, which blurs at any fractional offset.

- [x] **Step 1: Round the pan translate**

In `applyView()`, write the pan translate as whole screen pixels: `translate(${Math.round(x)}px, ${Math.round(y)}px) scale(${scale})` (keep `this.view.x/y` fractional internally so small wheel deltas still accumulate). A two-line comment above `applyView()` says why.

- [x] **Step 2: Round the drag displacement**

During a card drag, round the temporary inline translate to whole screen pixels: with `s = this.view.scale`, use `tx = Math.round((drag.dx + mx / s) * s) / s` and likewise `ty`; write `${tx}px ${ty}px`. The final pushed `dx`/`dy` are already `Math.round`ed integers in stage units, which at scale 1 are whole pixels. At any other scale the card keeps whatever subpixel phase its layout gave it: it does not shimmer while moving, but it is not on a grid.

- [x] **Step 3: Drop the compositor hint**

Remove `will-change: transform` from `.stage`. Keep `transform-origin: 0 0`. Neither `backface-visibility: hidden` nor `translateZ(0)` is added — they are a common blur *cause*, not a fix. Where zoom is not 100%, text is still resampled by the CSS scale; that is expected.

- [x] **Step 4: Verify and commit**

`mix assets.build` clean; `mix test` green (no test covers the hook). Read the generated bundle to confirm the rounding is present.

```bash
cd ~/repos/grasp/grasp && mix format && cd .. && git add -A && git commit -m "Keep card text crisp while dragging and panning

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Coverage of the request.** Line height and font size (Task 2 tokens), wider cards (`--card-width: 60rem`), GitHub Light via Lumis (Tasks 1–2), drag/pan/zoom (Tasks 3–4), connectors that follow (Task 4). Milestone 3 is a separate plan.
- **Type consistency.** `offset` is `{integer, integer}` in Forest; the LiveView coerces `dx`/`dy` with `int/1`; the card renders `--dx`/`--dy` in px and `data-dx`/`data-dy` as bare integers, which the hook reads back with `parseInt`. `move_card` payload keys `card`, `dx`, `dy` match between hook and handler.
- **LiveView-patch safety.** The only hook-set attributes are the inline `translate` during a drag (cleared in `updated()`) and the SVG children inside `phx-update="ignore"`; the transform lives in a head `<style>`. The toolbar buttons that are client-only have no `phx-*` attributes.
- **Known soft spots.** Lumis's per-line divs are assumed to reproduce the source text exactly (tree-sitter highlighting is lossless; the fixture test guards the column base). Wheel-to-pan competes with horizontal code scrolling; the rule "horizontal wheel over an overflowing code body scrolls the code" is the compromise. A card drag carries the card's subtree with it — the offset lands on the `.node`, whose children are laid out inside it — so a branch keeps its shape; connectors follow either way.
