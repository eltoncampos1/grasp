# Grasp Canvas Frames and Job Edges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three fixes to what the reader sees on the canvas. (1) The canvas zooms out to 5%, so a whole review fits on one screen. (2) Groups an agent lays out through `set_cards` land in stacked frames that never overlap: a card is placed only beside an opener in its own group, and the placement pass keeps a group's cards clear of every other group's frame, header included. (3) Enqueueing an Oban job is an edge: a call to `Worker.new/1` or `Worker.new/2` on a module whose `perform/1` is an `oban_worker` entry point becomes a clickable call of kind `enqueue` on that `perform/1`, drawn dashed like a route, with the worker and its queue as the span's title, so the worker's callers menu lists every function that enqueues it.

**Architecture:** Fixes 1 and 2 live entirely in the canvas hook (`grasp/assets/js/hooks/canvas.js`): a constant, and the placement pass gaining a notion of frame boxes — the rectangle `drawFrames()` would draw round a group's cards — as obstacles for cards of other groups. Fix 3 is a resolution step modelled on `Grasp.Index.Routes`: a new `Grasp.Index.Jobs.resolve/2` runs after entry-point detection in both `Builder` and `Incremental`, retargets the matching calls and adds a `job` map; `Builder.call_json/1` writes it as `"job"`; `Grasp.Highlight` reads it into `data-kind="enqueue"` and a `title`; the stylesheet draws `enqueue` like `route`.

**Tech Stack:** Elixir, Phoenix LiveView (viewer), esbuild (`mix assets.build`), the Oban worker entry points already detected by `Grasp.Index.EntryPoints`.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 §Templates (a new bullet "Jobs are edges" after "Routes are edges"), §Index JSON (the `job` call field), Part 2 §Layout (placement against frames), §Card (enqueue span and edge), the zoom paragraph, §Known gaps (milestone 7.5), §Milestones (7.5).

## Global Constraints

- Public repo: fixture names stay within `SampleApp`/`acme`; never name any other project or a local filesystem path anywhere in the repo. `@moduledoc`/`@doc`/`@spec` on everything public; HEEx components use `attr`, not `@spec`. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new pass" are forbidden in code, comments and docs).
- Gates, run from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, and for tasks that touch the indexer or the fixture app `mix test --include integration`. Tasks touching `grasp/assets/**` also run `mix assets.build` and commit the refreshed `grasp/priv/static/assets/grasp.js` and `grasp.css`. Read each exit code; never chain a commit on a failed gate. Never `git add -A`; add files by path. Never stage `grasp/priv/static/assets/app.js` or `app.css` if they appear untracked (an external watcher writes them). Commit trailer exactly `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Sample-app facts viewer tests pin and no task may move: `SampleApp.Greeter.greet/2` spans lines 6..11 of `lib/sample_app/greeter.ex`; `SampleApp.Formatter.shout/1` spans 8..10; do not edit `greeter.ex`, `formatter.ex`, `hello_live.ex`, `greeting_component.ex`, `greet_html.ex`, `show.html.heex` or `router.ex`. In `greet_controller.ex` lines 1–15 stay exactly as they are (tests pin `show/2` at line 7 and `again/2` at line 15); new code is appended after line 15 only.
- The fixture index `grasp/test/fixtures/index.json` is regenerated only by the recipe at the top of `grasp/test/fixtures/regenerate.exs`, never hand-edited.
- The canvas hook has no JS test harness. Every JS change is verified by `mix assets.build` succeeding and by the reviewer reading the diff against the placement rules in this plan; the Elixir suite must stay green.
- Never run tests against the real `claude` or `gh` binaries or the network.

---

### Task 1: Enqueue edges in the indexer

**Files:** create `grasp/lib/grasp/index/jobs.ex`; modify `grasp/lib/grasp/index/builder.ex`, `grasp/lib/grasp/index/incremental.ex`, `grasp/lib/grasp/index/join.ex` (the `@type call` only), `grasp/test/fixtures/sample_app/lib/sample_app_web/greet_controller.ex`; create `grasp/test/grasp/index/jobs_test.exs`; modify `grasp/test/grasp/index/builder_test.exs`, `grasp/test/grasp/index/incremental_test.exs`; regenerate `grasp/test/fixtures/index.json`.

**Interfaces (produced):**

```elixir
# Grasp.Index.Jobs
@spec resolve([Grasp.Index.Join.function_record()], [map()]) :: [Grasp.Index.Join.function_record()]
# A call %{target: "Mod.new/1" | "Mod.new/2", kind: any, range} on a record, where an entry
# point of kind "oban_worker" has target "Mod.perform/1", becomes
#   %{target: "Mod.perform/1", kind: :enqueue, range: <unchanged>, job: %{worker: "Mod", queue: "mail"}}
# `queue` is the entry's meta["queue"], or "default" when the meta has none.
# Every other call is unchanged. Call order is unchanged (the call keeps its place).
# Duplicates: if the record already holds a call with the same target, kind and range, keep one.

# Grasp.Index.Join.@type call gains
#   required(:kind) => Tracer.kind() | :template | :route | :enqueue,
#   optional(:job) => %{worker: String.t(), queue: String.t()}

# Builder.call_json/1 writes "job" => %{"worker" => worker, "queue" => queue} when the call has :job.
```

**Interfaces (consumed):** `Grasp.Index.Routes.resolve/2` — read it first and mirror its module shape, doc voice and where it is wired: `Builder.run` line `records = functions |> classify(base, paths) |> Routes.resolve(entries)` becomes `... |> Routes.resolve(entries) |> Jobs.resolve(entries)`, and `Incremental` line `|> Routes.resolve(entry_points)` gains `|> Jobs.resolve(entry_points)` immediately after. Entry points reach both as JSON maps with string keys (`"kind"`, `"target"`, `"meta"`).

- [ ] **Step 1: Write the unit tests** in `grasp/test/grasp/index/jobs_test.exs`:

```elixir
defmodule Grasp.Index.JobsTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Jobs

  @perform "SampleApp.Workers.Mailer.perform/1"
  @range %{start: {4, 5}, end: {4, 40}}

  test "a call to a worker's new/1 is an enqueue on its perform/1" do
    assert [call] = resolve([call("SampleApp.Workers.Mailer.new/1", :remote)])

    assert call == %{
             target: @perform,
             kind: :enqueue,
             range: @range,
             job: %{worker: "SampleApp.Workers.Mailer", queue: "mail"}
           }
  end

  test "new/2 enqueues too" do
    assert [%{target: @perform, kind: :enqueue}] =
             resolve([call("SampleApp.Workers.Mailer.new/2", :remote)])
  end

  test "a worker with no queue in its meta is on the default queue" do
    entries = [%{"kind" => "oban_worker", "target" => @perform, "meta" => %{}}]
    [record] = Jobs.resolve([record([call("SampleApp.Workers.Mailer.new/1", :remote)])], entries)
    assert [%{job: %{queue: "default"}}] = record.calls
  end

  test "new/1 on a module that is not a worker is left alone" do
    call = call("SampleApp.Greeter.new/1", :remote)
    assert [^call] = resolve([call])
  end

  test "a worker's other functions are left alone" do
    call = call("SampleApp.Workers.Mailer.perform/1", :remote)
    assert [^call] = resolve([call])
  end

  test "only oban_worker entries name workers" do
    entries = [%{"kind" => "genserver", "target" => @perform, "meta" => %{}}]
    call = call("SampleApp.Workers.Mailer.new/1", :remote)
    [record] = Jobs.resolve([record([call])], entries)
    assert record.calls == [call]
  end

  test "the call keeps its place among the record's calls" do
    first = call("SampleApp.Greeter.greet/1", :remote, %{start: {2, 1}, end: {2, 6}})
    last = call("SampleApp.Greeter.greet/2", :remote, %{start: {6, 1}, end: {6, 6}})
    enqueue = call("SampleApp.Workers.Mailer.new/1", :remote)

    assert [^first, %{kind: :enqueue}, ^last] = resolve([first, enqueue, last])
  end

  test "a record without calls is unchanged" do
    record = %{id: "SampleApp.Greeter.greet/1", calls: []}
    assert [^record] = Jobs.resolve([record], entries())
  end

  defp resolve(calls) do
    [record] = Jobs.resolve([record(calls)], entries())
    record.calls
  end

  defp record(calls), do: %{id: "SampleAppWeb.GreetController.enqueue/2", calls: calls}

  defp call(target, kind, range \\ @range), do: %{target: target, kind: kind, range: range}

  defp entries do
    [
      %{
        "kind" => "route",
        "label" => "GET /greet/:name",
        "target" => "SampleAppWeb.GreetController.show/2",
        "meta" => %{"verb" => "GET", "path" => "/greet/:name"}
      },
      %{
        "kind" => "oban_worker",
        "label" => @perform,
        "target" => @perform,
        "meta" => %{"queue" => "mail", "max_attempts" => 5}
      }
    ]
  end
end
```

- [ ] **Step 2: Run them to see them fail** — `cd grasp && mix test test/grasp/index/jobs_test.exs`. Expected: compile error, `Grasp.Index.Jobs` undefined.

- [ ] **Step 3: Write `grasp/lib/grasp/index/jobs.ex`:**

```elixir
defmodule Grasp.Index.Jobs do
  @moduledoc """
  Turns a call that enqueues an Oban job into a call on the worker that runs it.

  `use Oban.Worker` gives a worker a `new/1` and a `new/2` that build the job changeset,
  and enqueueing reads `Worker.new(args) |> Oban.insert()`. The compiler reports that as a
  call to `Worker.new/1`, a function no source file defines, so on its own it reaches
  nothing the index holds; the work it sets in motion is `Worker.perform/1`. This pass
  redirects the call there, as a call of kind `:enqueue` carrying the worker and the queue
  it runs on, so the enqueueing function reads as a caller of the worker and the site is a
  hop the reader can follow.

  Which modules are workers is what the `oban_worker` entry points say: a call to `new/1`
  or `new/2` on any other module is left as it is. A job enqueued some other way — through
  `Oban.Job.new/2` with a `worker:` option, or a changeset built somewhere else and passed
  to `Oban.insert_all/2` — names no worker at the call site and is not followed.
  """

  alias Grasp.Index.Join

  @doc """
  Redirects every enqueueing call on `records` to the worker's `perform/1`.

  `entries` are entry points in the JSON shape the document holds them in, as
  `Grasp.Index.Builder.entry_point_json/1` writes them; only the `oban_worker` ones are
  read. A call keeps its range and its place in the record's calls.
  """
  @spec resolve([Join.function_record()], [map()]) :: [Join.function_record()]
  def resolve(records, entries) do
    workers =
      for %{"kind" => "oban_worker", "target" => target} = entry <- entries,
          [worker] <- [worker_of(target)],
          into: %{} do
        {worker, %{target: target, queue: queue(entry)}}
      end

    if workers == %{}, do: records, else: Enum.map(records, &resolve_record(&1, workers))
  end

  # "Mod.perform/1" -> ["Mod"]; anything else -> []
  defp worker_of(target) do
    case Regex.run(~r/\A(.+)\.perform\/1\z/, target) do
      [_all, worker] -> [worker]
      nil -> []
    end
  end

  defp queue(%{"meta" => %{"queue" => queue}}) when is_binary(queue), do: queue
  defp queue(_entry), do: "default"

  defp resolve_record(%{calls: calls} = record, workers) do
    %{record | calls: calls |> Enum.map(&call(&1, workers)) |> Enum.uniq()}
  end

  defp resolve_record(record, _workers), do: record

  defp call(%{target: target} = call, workers) do
    case Regex.run(~r/\A(.+)\.new\/[12]\z/, target) do
      [_all, worker] ->
        case Map.fetch(workers, worker) do
          {:ok, %{target: perform, queue: queue}} ->
            %{target: perform, kind: :enqueue, range: call.range, job: %{worker: worker, queue: queue}}

          :error ->
            call
        end

      nil ->
        call
    end
  end
end
```

Then in `join.ex`, extend `@type call` to `required(:kind) => Tracer.kind() | :template | :route | :enqueue` and add `optional(:job) => %{worker: String.t(), queue: String.t()}` with a comment in the same voice as the `:route` one: `:job` is written by `Grasp.Index.Jobs` on a call of kind `:enqueue` alone and names the worker and the queue the job runs on.

- [ ] **Step 4: Run the unit tests** — `mix test test/grasp/index/jobs_test.exs`. Expected: all pass.

- [ ] **Step 5: Wire it into Builder and Incremental, and write `"job"`.** In `builder.ex`: alias `Grasp.Index.Jobs`; `records = functions |> classify(base, paths) |> Routes.resolve(entries) |> Jobs.resolve(entries)`; extend the `@moduledoc` sentence that lists the pipeline (`Grasp.Index.Routes.resolve/2`) to name `Grasp.Index.Jobs.resolve/2` too; in `call_json/1`, add a clause so a call with `%{job: %{worker: worker, queue: queue}}` writes `"job" => %{"worker" => worker, "queue" => queue}` (keep the `route` clause; a call has one or neither), and extend the comment above `call_json/1` with one sentence: a call of kind `:enqueue` carries the worker and queue the job runs on. In `incremental.ex`: alias and `|> Jobs.resolve(entry_points)` right after `|> Routes.resolve(entry_points)`; extend the moduledoc sentence about resolving route sites to say enqueueing calls are resolved against the workers the same way.

- [ ] **Step 6: Give the sample app an enqueue site.** Append to `greet_controller.ex` after line 15, keeping lines 1–15 byte-identical:

```elixir

  @doc "Queues a greeting to be mailed."
  def mail(conn, %{"name" => name}) do
    _job = SampleApp.Workers.Mailer.new(%{"name" => name})
    text(conn, "queued")
  end
```

Do not add a route for it and do not call `Oban.insert` (nothing runs Oban in the fixture). The call is on line 19, columns 12..56 (`SampleApp.Workers.Mailer.new(%{"name" => name})`, end exclusive) — verify against what the integration test prints rather than trusting these numbers, and pin the range the indexer actually produced.

- [ ] **Step 7: Integration tests.** In `builder_test.exs`, after the route test, add:

```elixir
  test "enqueueing a job is a call on the worker that performs it", %{index: index} do
    {:ok, mail} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.mail/2")

    assert %{
             "kind" => "enqueue",
             "range" => %{"start" => [19, 12], "end" => [19, 56]},
             "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"}
           } = call(mail, "SampleApp.Workers.Mailer.perform/1")

    assert call(mail, "SampleApp.Workers.Mailer.new/1") == nil

    assert "SampleAppWeb.GreetController.mail/2" in
             Grasp.Index.callers(index, "SampleApp.Workers.Mailer.perform/1")
  end
```

(Use the file's existing `call/2` helper; adjust the range to the indexer's own output if it differs.) In `incremental_test.exs`, inside or beside the `describe "update/5 over a template that links to a route"` block, add one test in the same shape asserting that after an update rebuilding `greet_controller.ex`, `mail/2` holds a call of kind `"enqueue"` on `SampleApp.Workers.Mailer.perform/1` with `"job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"}`. Read the neighbouring test to see how it drives `update/5` and what document it starts from.

- [ ] **Step 8: Regenerate the fixture index** with the recipe at the top of `grasp/test/fixtures/regenerate.exs`, then run the gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix test --include integration`. Expected: all green; the only fixture records that change are `GreetController.mail/2` (new) and the `entry_points`/`modules` blocks if they move.

- [ ] **Step 9: Commit** `grasp/lib/grasp/index/jobs.ex`, `builder.ex`, `incremental.ex`, `join.ex`, `greet_controller.ex`, the three test files and `grasp/test/fixtures/index.json`. Message: `Enqueueing a job is a call on its worker` with a body of two or three sentences on what the pass does and does not follow, plus the trailer.

---

### Task 2: Enqueue edges in the viewer, and the zoom floor

**Files:** modify `grasp/lib/grasp/highlight.ex`, `grasp/assets/css/app.css`, `grasp/assets/js/hooks/canvas.js` (MIN_SCALE only in this task), `grasp/test/grasp/highlight_test.exs`, `grasp/guides/getting-started.md` if it states a zoom range (grep `25`); rebuild `grasp/priv/static/assets/grasp.js` and `grasp.css`.

**Interfaces (consumed):** Task 1's `"job"` field on a call: `%{"worker" => String.t(), "queue" => String.t()}`, present only on calls of kind `"enqueue"`.

- [ ] **Step 1: Highlight test.** Find how `grasp/test/grasp/highlight_test.exs` asserts the route span (`data-kind="route"` with `title="GET /greet/:name"`) and add a sibling test: a record whose `calls` holds `%{"target" => "SampleApp.Workers.Mailer.perform/1", "kind" => "enqueue", "range" => ..., "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"}}` over a source line `SampleApp.Workers.Mailer.new(%{})` renders a `<span class="call" ... data-kind="enqueue" title="Oban job · SampleApp.Workers.Mailer · mail" ...>`. Also assert a route span still renders exactly as before, and a plain remote call carries neither `data-kind` nor `title`. Run it; expected: fails on the missing attributes.

- [ ] **Step 2: Implement in `highlight.ex`.** Where `ranges` are built (the comprehension around line 236), carry `job: call["job"]` beside `route:`. Rename `route_attrs/1` to `kind_attrs/1` with three clauses:

```elixir
  # A hop that is not a function call — an HTTP request the router resolved, a job put on
  # a queue — says which kind it is, and the title carries what the reader would otherwise
  # have to look up: the route's verb and path, or the worker and the queue it runs on.
  defp kind_attrs(%{kind: "route", route: %{"verb" => verb, "path" => path}}),
    do: ~s( data-kind="route" title="#{escape(verb)} #{escape(path)}")

  defp kind_attrs(%{kind: "enqueue", job: %{"worker" => worker, "queue" => queue}}),
    do: ~s( data-kind="enqueue" title="Oban job · #{escape(worker)} · #{escape(queue)}")

  defp kind_attrs(_range), do: ""
```

Update the moduledoc sentence at line ~23 that says a call the router resolved carries `data-kind="route"` to cover `enqueue` too.

- [ ] **Step 3: Stylesheet.** In `grasp/assets/css/app.css` change the two selectors to match either kind:

```css
.connectors .edge[data-kind="route"],
.connectors .edge[data-kind="enqueue"] { stroke-dasharray: 6 4; }
```
and
```css
.call[data-kind="route"],
.call[data-kind="enqueue"] { border-bottom-style: dotted; }
```
Keep any comment beside them accurate (the comment describes hops that are not function calls).

- [ ] **Step 4: Zoom floor.** In `canvas.js` set `const MIN_SCALE = 0.05`. Read the comment near line 982 ("thinning to under half a one at MIN_SCALE") and the one at line 20 and adjust any sentence that quotes the old floor as a number; the `vector-effect` reasoning still holds. Grep `grasp/guides` and `README.md` for `25%`/`0.25` and fix any statement of the range.

- [ ] **Step 5: Gates.** `mix assets.build`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Expected: green. Commit `highlight.ex`, `app.css`, `canvas.js`, `highlight_test.exs`, any guide touched, and `grasp/priv/static/assets/grasp.js` + `grasp.css`. Message: `A queued job reads as a hop, and the canvas zooms out to 5%` plus trailer.

---

### Task 3: Groups placed clear of one another

**Files:** modify `grasp/assets/js/hooks/canvas.js` (`placeCards()`, `drawFrames()`, helpers), rebuild `grasp/priv/static/assets/grasp.js`.

**Interfaces (consumed):** `drawFrames()` computes per-group frames as `{left: extent.left - FRAME_PAD, top: extent.top - head, right: extent.right + FRAME_PAD, bottom: extent.bottom + FRAME_PAD}` where `head = FRAME_PAD` for an untitled group and `titleHeight/scale + FRAME_TITLE_GAP/scale + FRAME_PAD` for a titled one; a section's header element is `.flow[data-grouped][data-group=ID] .flow__title`. Nodes carry `data-group` (`""` for none), `data-depth`, `data-card`; `sortGroup()` orders groups before the groupless section.

**Placement rules this task implements** (these are the spec; the reviewer checks the code against them):

1. **Same-group openers only.** `opener` is the first call site naming the card whose node is placed AND whose `dataset.group === node.dataset.group`. Likewise `calls` (the caller-to-the-left rule) only considers a callee in the same group. A grouped card called only from another group is therefore a root of its own group.
2. **Frames are obstacles for other groups.** Before the loop, and again whenever a placement lands, compute `frameBoxes`: for each group id (not `""`) with at least one box in `occupied`, the frame rectangle per the formula above, measuring `head` from that group's `.flow__title` element (`getBoundingClientRect().height / scale`; `FRAME_PAD` alone when there is no title element). A card of group G is nudged past every card box (as today) AND past every frame box of a group other than G. A groupless card (`""`) is nudged past every frame. Implement by building the obstacle list per card: `occupied.concat(frameBoxes.filter(f => f.group !== group))`.
3. **A new group starts below everything.** A root whose group has no placed peers starts at `x = 0`, `y = max(bottom of every card box and every frame box) + GAP_Y + head`, where `head` is its own group's header allowance (so its frame's top clears the frame above by GAP_Y). With nothing placed at all, `(0, head)` — the header allowance keeps the first frame's title on the stage. A groupless root with no groupless peers starts under everything the same way with `head = 0`.
4. **A root with peers** keeps the current rule: `x = min left of peers`, `y = max bottom of peers + GAP_Y`, then the nudge loop.
5. **The nudge loop** stays strictly downward and must also grow `frameBoxes` after each placement (recompute the placed card's group frame from its boxes), so the next group in the same pass sees the frame the previous group just grew to.

Extract the frame formula into one function used by both `drawFrames()` and `placeCards()` so the two cannot disagree:

```js
// The rectangle drawn round a group's cards: FRAME_PAD on three sides and, above, room for
// the header the group carries. `extent` is the union of the cards' boxes in stage units.
function frameAround(extent, headerHeight) {
  const head = headerHeight === null ? FRAME_PAD : headerHeight + FRAME_TITLE_GAP_STAGE + FRAME_PAD
  return {left: extent.left - FRAME_PAD, top: extent.top - head, right: extent.right + FRAME_PAD, bottom: extent.bottom + FRAME_PAD}
}
```
(`FRAME_TITLE_GAP / scale` must be passed or computed consistently; `drawFrames()` already divides by scale — keep one convention and name it.) Add a method `headerHeightOf(groupId)` that returns the `.flow__title` height in stage units or `null`.

- [ ] **Step 1: Read `placeCards()` and `drawFrames()` in full**, then implement rules 1–5 and the shared `frameAround`. Update the comments in `placeCards()` that explain the root rule ("a group with nothing in it starts at the stage's corner, and the overlap pass below is what stacks one such group under another") to state the rules above as durable facts.

- [ ] **Step 2: `mix assets.build`** from `grasp/`; expected: succeeds with no warnings. `mix test`; expected: green (no Elixir touched, but the gate is the rule).

- [ ] **Step 3: Self-check by reading**, and write the answers into your report: (a) with two titled groups A and B, B called from A, where does B's first card land relative to A's frame bottom? (expected: A.frame.bottom + GAP_Y + B.head, so B.frame.top = A.frame.bottom + GAP_Y); (b) a groupless card called from a grouped card — placed beside the opener or under all frames? (expected: under all frames; the groupless section is laid out last); (c) does `drawFrames()` still produce the same rectangles as before for a titled group? (expected: yes; only the function's home moved).

- [ ] **Step 4: Commit** `canvas.js` and `grasp/priv/static/assets/grasp.js`. Message: `Groups are laid out clear of one another` plus trailer, with a body stating the three rules in one sentence each.

---

### Task 4: Documentation

**Files:** modify `docs/specs/2026-09-15-grasp-design.md`, `grasp/guides/reviewing.md`, `grasp/guides/indexing.md`, `README.md` and `grasp/README.md` where they list what the index follows.

- [ ] **Step 1: Spec.** (a) After the "Routes are edges" bullet in Part 1 §Templates add a bullet **"Jobs are edges."** stating: a call to `Worker.new/1` or `new/2` on a module whose `perform/1` is an `oban_worker` entry point is a call of kind `enqueue` on that `perform/1`, resolved by `Grasp.Index.Jobs.resolve/2` after entry-point detection in both the builder and the incremental path; it carries `job: %{worker, queue}` (queue from the worker's `__opts__/0`, `"default"` when absent); the span renders `data-kind="enqueue"` with title `Oban job · Worker · queue`, the edge dashed; the enqueueing function is a caller of the worker. (b) In §Index JSON, beside the `route` call field, document `"job": {"worker", "queue"}` on `enqueue` calls. (c) In Part 2 §Layout, replace the sentence "a card with no placed neighbour is a root and goes under the lowest placed card of its group, at its group's left edge, so groups stack downwards" with the rules from Task 3: openers count only within a card's own group; a group's cards are kept clear of every other group's frame, header included, so frames stack downwards with one gap between them and never overlap when laid out; a new group starts below everything on the canvas; the groupless section is placed last, under every frame. (d) In the zoom paragraph, state the range: the scale runs from 5% to 250%. (e) Add `### Known gaps (milestone 7.5)`: enqueues through `Oban.Job.new/2` with `worker:`, `Oban.insert_all/2` over prebuilt changesets, and a worker module held in a variable are not followed; a frame a reader has dragged can still overlap another (placement, not dragging, is what stays clear); the incremental path resolves enqueues only on rebuilt records, like routes. (f) In §Milestones, add 7.5 in the style of 7.2–7.4: canvas frames laid out clear of one another, 5% zoom floor, enqueue edges.

- [ ] **Step 2: Guides and READMEs.** In `grasp/guides/indexing.md`, where route edges are explained, add a short paragraph on job edges. In `grasp/guides/reviewing.md`, where the route's dotted underline is described (grep `dotted` or `route`), say the same underline and dashed edge mark a job being queued, with the worker and queue in the tooltip. In `README.md` and `grasp/README.md`, wherever the feature list names route arrows, add job edges in the same breath. No history words.

- [ ] **Step 3: Gates and commit.** `mix format --check-formatted` (from `grasp/`; docs are not formatted but the gate is the rule), then commit the docs: `Docs: jobs are edges, frames stack clear, zoom to 5%` plus trailer.
