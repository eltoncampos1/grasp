# Grasp Re-resolution on Incremental Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An incremental update re-resolves every record in the document — the rebuilt ones and the kept ones — against the entry points it has just detected, so a route added to the router or a worker added to the project reaches an untouched template or function on the next save instead of the next full build.

**Architecture:** Route and job edges are derived from two inputs the document today throws away: a record's route sites and the `Worker.new/N` call an enqueue edge replaced. The document keeps both: every function record carries `"route_sites"` (verb, segments, range), and every call of kind `"enqueue"` carries `"via"` (the target and kind of the call it stands for). A new `Grasp.Index.Resolve` owns resolution end to end: `resolve/2` runs `Routes.resolve/2` then `Jobs.resolve/2` over records (used by `Builder` and `Incremental` for rebuilt records), and `refresh/2` takes a function record in its JSON shape, undoes the previous resolution (drops route calls, reverts enqueue calls to their `via`), decodes the raw inputs, runs the same two resolvers, and encodes the calls back. `Incremental.update/5` maps `refresh/2` over the kept records. A record written by an earlier Grasp has no `"route_sites"` key and is left as it is, so an old document loses nothing on its first save.

**Tech Stack:** Elixir; no viewer or JS change.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 1 §Templates "Routes are edges" and "Jobs are edges" (inputs kept in the document), §Index JSON (`route_sites`, `via`), the incremental-update prose, §Known gaps (the 7.3 and 7.5 bullets on incremental re-resolution go), §Milestones (7.6).

## Global Constraints

- Public repo: fixture names stay within `SampleApp`/`acme`; never name any other project or a local filesystem path anywhere in the repo or commit messages. `@moduledoc`/`@doc`/`@spec` on everything public. Comments and docs state durable facts, never history ("was", "now", "previously", "no longer", "per review", "new" as in "the new key", "today", "changed", "used to" are forbidden in code, comments and docs).
- Gates, run from `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix test --include integration`. Read each exit code; never chain a commit on a failed gate. Known flake: `Grasp.ReindexerTest` debounce timeout — re-run once and report both runs. Never `git add -A`; add files by path. Never stage `grasp/priv/static/assets/app.js` or `app.css` if they appear untracked. Commit trailer exactly `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Frozen fixture sources: nothing under `grasp/test/fixtures/sample_app/` is edited in this plan. The fixture index `grasp/test/fixtures/index.json` is regenerated only by the recipe at the top of `grasp/test/fixtures/regenerate.exs`, never hand-edited.
- Never run tests against the real `claude` or `gh` binaries or the network (beyond `mix deps.get` in the sample app if its deps are missing).

---

### Task 1: The document keeps its inputs, and an update re-resolves every record

**Files:** create `grasp/lib/grasp/index/resolve.ex`; modify `grasp/lib/grasp/index/routes.ex`, `grasp/lib/grasp/index/jobs.ex`, `grasp/lib/grasp/index/join.ex` (`@type call`), `grasp/lib/grasp/index/builder.ex`, `grasp/lib/grasp/index/incremental.ex`; create `grasp/test/grasp/index/resolve_test.exs`; modify `grasp/test/grasp/index/routes_test.exs`, `grasp/test/grasp/index/jobs_test.exs`, `grasp/test/grasp/index/builder_test.exs`, `grasp/test/grasp/index/incremental_test.exs`; regenerate `grasp/test/fixtures/index.json`.

**Interfaces (produced):**

```elixir
# Grasp.Index.Routes.resolve/2 — KEEPS :route_sites on the record (no Map.delete). Everything else unchanged.

# Grasp.Index.Jobs — an enqueue call gains :via
#   %{target: "Mod.perform/1", kind: :enqueue, range: r, job: %{worker: "Mod", queue: "mail"},
#     via: %{target: "Mod.new/2", kind: :remote}}
# Join.@type call: optional(:via) => %{target: String.t(), kind: Tracer.kind() | :template}

# Grasp.Index.Resolve
@spec resolve([Join.function_record()], [map()]) :: [Join.function_record()]
#   Routes.resolve(records, entries) |> Jobs.resolve(entries)
@spec refresh(map(), [map()]) :: map()
#   function JSON in, function JSON out. A record without the "route_sites" key is returned as is.
#   Otherwise: calls = record["calls"] minus kind "route", each kind "enqueue" call with a "via"
#   replaced by %{"target" => via.target, "kind" => via.kind, "range" => range}; decode calls and
#   route_sites to record shape; %{id, calls, route_sites} |> resolve(entries); encode calls back;
#   Map.put(record, "calls", calls). "route_sites" is written back unchanged.
@spec call_json(Join.call()) :: map()          # moved out of Builder; writes "route", "job", "via"
@spec call_record(map()) :: Join.call()        # inverse, atoms for kind; keeps route/job/via
@spec route_site_json(Extract.route_site()) :: map()
#   %{"verb" => v, "path" => segments, "range" => %{"start" => [l, c], "end" => [l, c]}}
#   with :dynamic encoded as JSON null in the segments list
@spec route_site_record(map()) :: Extract.route_site()

# Builder.function_json/1 writes "route_sites" => Enum.map(record.route_sites || [], &Resolve.route_site_json/1)
# (always present, [] when none — the key is what marks a record as carrying its inputs).
# Builder.run and Incremental.update call Resolve.resolve/2 instead of the two resolvers.
# Incremental.update: functions = (records |> Resolve.resolve(entry_points) |> Enum.map(&Builder.function_json/1))
#                                ++ Enum.map(kept, &Resolve.refresh(&1, entry_points)), then sort_functions.
```

- [ ] **Step 1: Adjust the existing resolver tests to the kept inputs.** In `routes_test.exs`: every `refute Map.has_key?(resolved, :route_sites)` becomes `assert resolved.route_sites == <the sites passed in>`; the test "returns a record with no route sites unchanged, and without the key" becomes "returns a record with no route sites unchanged" (a record given no `:route_sites` key comes back without one — `Routes.resolve` adds nothing). In `jobs_test.exs`: the first test's expected call gains `via: %{target: "SampleApp.Workers.Mailer.new/1", kind: :remote}`; add `test "an enqueue call remembers the call it stands for"` asserting `via` for a `new/2` call of kind `:imported` is `%{target: ".../new/2", kind: :imported}`. Run both files; expect failures.

- [ ] **Step 2: Routes keeps the sites; Jobs writes `via`.** In `routes.ex` `resolve_record/2`: drop both `Map.delete(record, :route_sites)` calls (the `[]` branch returns `record`; the other branch only `Map.put(:calls, ...)`); update the `@doc` ("Records keep their `:route_sites`: the document carries them so an update can resolve them again") and the moduledoc sentence about sites saying all they can say. In `jobs.ex` `call/2`: add `via: %{target: target, kind: call.kind}` to the built map; `@doc` gains one sentence. In `join.ex`: `optional(:via) => %{target: String.t(), kind: Tracer.kind() | :template}` with a comment in the voice of the `:route`/`:job` ones (`:via` is the call an enqueue edge stands for, kept so the edge can be undone and drawn again when the workers change). Run the two test files; expect pass.

- [ ] **Step 3: `Grasp.Index.Resolve` unit tests** in `grasp/test/grasp/index/resolve_test.exs`:

```elixir
defmodule Grasp.Index.ResolveTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Resolve

  @show "SampleAppWeb.GreetController.show/2"
  @perform "SampleApp.Workers.Mailer.perform/1"
  @range %{"start" => [3, 9], "end" => [3, 21]}

  describe "refresh/2" do
    test "resolves a kept record's route sites against routes that appear" do
      record = json(calls: [], route_sites: [site("GET", ["greet", "bob"])])

      assert %{"calls" => []} = Resolve.refresh(record, [])

      assert %{"calls" => [call]} = Resolve.refresh(record, [route("GET", "/greet/:name", @show)])
      assert call == %{"target" => @show, "kind" => "route", "range" => @range,
                       "route" => %{"verb" => "GET", "path" => "/greet/:name"}}
    end

    test "drops a route call whose route is gone" do
      record = json(calls: [route_call()], route_sites: [site("GET", ["greet", "bob"])])
      assert %{"calls" => []} = Resolve.refresh(record, [])
    end

    test "keeps the record's route sites" do
      sites = [site("GET", ["greet", "bob"])]
      assert %{"route_sites" => ^sites} = Resolve.refresh(json(calls: [], route_sites: sites), [])
    end

    test "reverts an enqueue call whose worker is gone, and draws it again when it is back" do
      enqueue = %{"target" => @perform, "kind" => "enqueue", "range" => @range,
                  "job" => %{"worker" => "SampleApp.Workers.Mailer", "queue" => "mail"},
                  "via" => %{"target" => "SampleApp.Workers.Mailer.new/1", "kind" => "remote"}}
      record = json(calls: [enqueue], route_sites: [])

      assert %{"calls" => [reverted]} = Resolve.refresh(record, [])
      assert reverted == %{"target" => "SampleApp.Workers.Mailer.new/1", "kind" => "remote", "range" => @range}

      assert %{"calls" => [^enqueue]} = Resolve.refresh(record, [worker("mail")])
      assert %{"calls" => [%{"job" => %{"queue" => "later"}}]} = Resolve.refresh(record, [worker("later")])
    end

    test "leaves a plain call, and a call's position among the others, alone" do
      first = %{"target" => "SampleApp.Greeter.greet/1", "kind" => "remote", "range" => %{"start" => [1, 1], "end" => [1, 6]}}
      last = %{"target" => "SampleApp.Greeter.greet/2", "kind" => "remote", "range" => %{"start" => [9, 1], "end" => [9, 6]}}
      record = json(calls: [first, route_call(), last], route_sites: [site("GET", ["greet", "bob"])])

      assert %{"calls" => [^first, %{"kind" => "route"}, ^last]} =
               Resolve.refresh(record, [route("GET", "/greet/:name", @show)])
    end

    test "is idempotent" do
      entries = [route("GET", "/greet/:name", @show), worker("mail")]
      record = json(calls: [route_call()], route_sites: [site("GET", ["greet", "bob"])])
      once = Resolve.refresh(record, entries)
      assert Resolve.refresh(once, entries) == once
    end

    test "leaves a record written without its inputs as it is" do
      legacy = Map.delete(json(calls: [route_call()], route_sites: []), "route_sites")
      assert Resolve.refresh(legacy, []) == legacy
    end

    test "reads a dynamic segment back from the document" do
      record = json(calls: [], route_sites: [site("GET", ["greet", nil])])
      assert %{"calls" => [%{"kind" => "route"}]} = Resolve.refresh(record, [route("GET", "/greet/:name", @show)])
    end
  end

  test "resolve/2 runs routes then jobs over records" do
    record = %{id: "SampleAppWeb.GreetHTML.show/1",
               calls: [%{target: "SampleApp.Workers.Mailer.new/1", kind: :remote, range: %{start: {5, 1}, end: {5, 6}}}],
               route_sites: [%{verb: "GET", path: ["greet", "bob"], range: %{start: {3, 9}, end: {3, 21}}}]}

    assert [%{calls: calls, route_sites: [_site]}] =
             Resolve.resolve([record], [route("GET", "/greet/:name", @show), worker("mail")])

    assert Enum.map(calls, &{&1.target, &1.kind}) == [{@show, :route}, {@perform, :enqueue}]
  end

  defp json(calls: calls, route_sites: sites),
    do: %{"id" => "SampleAppWeb.GreetHTML.show/1", "file" => "lib/sample_app_web/greet_html/show.html.heex",
          "calls" => calls, "route_sites" => sites}

  defp site(verb, path), do: %{"verb" => verb, "path" => path, "range" => @range}

  defp route_call,
    do: %{"target" => @show, "kind" => "route", "range" => @range, "route" => %{"verb" => "GET", "path" => "/greet/:name"}}

  defp route(verb, path, target),
    do: %{"kind" => "route", "label" => "#{verb} #{path}", "target" => target, "meta" => %{"verb" => verb, "path" => path}}

  defp worker(queue),
    do: %{"kind" => "oban_worker", "label" => @perform, "target" => @perform, "meta" => %{"queue" => queue}}
end
```
Run; expect `Grasp.Index.Resolve` undefined.

- [ ] **Step 4: Write `grasp/lib/grasp/index/resolve.ex`.** Moduledoc: what resolution is (two passes, both derived from inputs the document keeps), why the document keeps them (an update detects entry points afresh and resolves every record against them, so a route or worker that appears or goes reaches a record whose file did not recompile), and the legacy rule (a record with no `"route_sites"` key predates the inputs and is left as it is). Implementation sketch:

```elixir
  def resolve(records, entries), do: records |> Routes.resolve(entries) |> Jobs.resolve(entries)

  def refresh(%{"route_sites" => sites} = record, entries) when is_list(sites) do
    calls =
      record["calls"]
      |> List.wrap()
      |> Enum.reject(&(&1["kind"] == "route"))
      |> Enum.map(&unresolved/1)
      |> Enum.map(&call_record/1)

    [resolved] =
      resolve([%{id: record["id"], calls: calls, route_sites: Enum.map(sites, &route_site_record/1)}], entries)

    Map.put(record, "calls", Enum.map(resolved.calls, &call_json/1))
  end

  def refresh(record, _entries), do: record

  # An enqueue edge stands for the call it replaced, which is what the workers are matched against.
  defp unresolved(%{"kind" => "enqueue", "via" => %{"target" => target, "kind" => kind}} = call),
    do: %{"target" => target, "kind" => kind, "range" => call["range"]}

  defp unresolved(call), do: call
```
`call_json/1` is the body of `Builder.call_json/1` moved here, plus a `via` clause (`"via" => %{"target" => t, "kind" => Atom.to_string(k)}`); `call_record/1` reads `"target"`, `"kind"` (`String.to_existing_atom/1` — every kind the document writes is an atom the tracer, `:template`, `:route` or `:enqueue` already defines), `"range"` (`%{start: {l, c}, end: {l, c}}`), and `"route"`/`"job"`/`"via"` when present (atom keys, `via.kind` to an existing atom). `route_site_json/1` writes `:dynamic` as `nil`; `route_site_record/1` reads `nil` back to `:dynamic`. Mind the `Routes.resolve` sort: it orders calls by `{range.start, target, kind}` only when the record has sites, so a refreshed record's order is stable — the idempotence test pins that. Run `resolve_test.exs`; expect pass.

- [ ] **Step 5: Wire Builder and Incremental.** `builder.ex`: alias `Resolve`; `records = functions |> classify(base, paths) |> Resolve.resolve(entries)`; `function_json/1` writes `"calls" => Enum.map(record.calls, &Resolve.call_json/1)` and `"route_sites" => record |> Map.get(:route_sites, []) |> Enum.map(&Resolve.route_site_json/1)`; delete the private `call_json/1` and its comment (the comment's fact moves to `Resolve.call_json/1`'s `@doc`); moduledoc pipeline sentence names `Grasp.Index.Resolve.resolve/2`. `incremental.ex`: alias `Resolve` (drop the now-unused `Routes`/`Jobs` aliases if nothing else uses them); replace the `functions =` pipeline with the shape in the interfaces block; rewrite the moduledoc paragraph about resolving only the rebuilt records to state that every record — kept and rebuilt — is resolved against the entry points the update detects, since the document carries each record's inputs. Compile with `--warnings-as-errors`.

- [ ] **Step 6: Integration tests.** In `builder_test.exs` add, after the enqueue test:

```elixir
  test "the document keeps the inputs its edges are resolved from", %{index: index} do
    {:ok, show} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetHTML.show/1")

    assert %{"verb" => "GET", "path" => ["greet", "bob"], "range" => %{"start" => [3, 9], "end" => [3, 21]}} in
             show["route_sites"]

    {:ok, mail} = Grasp.Index.fetch_function(index, "SampleAppWeb.GreetController.mail/2")
    assert %{"via" => %{"target" => "SampleApp.Workers.Mailer.new/1", "kind" => "remote"}} =
             call(mail, "SampleApp.Workers.Mailer.perform/1")

    {:ok, greet} = Grasp.Index.fetch_function(index, "SampleApp.Greeter.greet/2")
    assert greet["route_sites"] == []
  end
```
In `incremental_test.exs`, next to the `describe "update/5 over a template that links to a route"` block, add a describe "update/5 over a file that did not change" with two tests, built the way its neighbours build a document and call `update/5` (read them first): (a) start from a document whose `entry_points` lack the `GET /hello` live route, update a file that is NOT the template (`lib/sample_app/greeter.ex` say, with events for it), and assert the kept `SampleAppWeb.GreetHTML.show/1` record now carries a call of kind `"route"` to `SampleAppWeb.HelloLive.mount/3` — the entry points come from the document when detection is unavailable, so put the full route list (including `/hello`) into the document the update reads, and the route-less list into the record's calls beforehand; (b) start from a document whose entry points hold no `oban_worker` entry, assert the kept `mail/2` record's enqueue call is reverted to `SampleApp.Workers.Mailer.new/1` of kind `"remote"`. If detection IS available in the test VM (`EntryPoints.available?/1` true), pick whichever lever the existing tests use to control entry points and say so in your report.

- [ ] **Step 7: Regenerate the fixture index** with the recipe at the top of `grasp/test/fixtures/regenerate.exs`, then the gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix test --include integration`. Expected: every record gains `"route_sites"`, the `mail/2` enqueue call gains `"via"`, nothing else moves.

- [ ] **Step 8: Commit** all files by path. Message: `An update resolves every record against the entry points it finds` with a body of three sentences (inputs kept, kept records refreshed, legacy records untouched) plus the trailer.

---

### Task 2: Documentation

**Files:** `docs/specs/2026-09-15-grasp-design.md`, `grasp/guides/indexing.md`.

- [ ] **Step 1: Spec.** (a) "Routes are edges" bullet: replace the clause saying records come back without their route sites with: route sites stay on the record and in the document. (b) "Jobs are edges" bullet: an enqueue call carries `via`, the call it stands for. (c) §Index JSON: document `"route_sites": [{"verb", "path": [segment | null], "range"}]` on every function record (`null` is a segment the template computes) and `"via": {"target", "kind"}` on enqueue calls. (d) The incremental-update paragraph (search "Only the rebuilt records are resolved" or its rewritten form in Part 4): state that every record is resolved against the entry points the update detects; a record written without its inputs is left as it is. (e) Remove the Known-gaps bullets "An incremental update re-resolves only the records it rebuilds" (7.5) and the equivalent 7.3 bullet. (f) §Milestones: add 7.6 in the style of 7.5.
- [ ] **Step 2: Indexing guide.** In the reindexer section's bullet list, reword the "a Grasp upgrade" bullet: a document written by an earlier Grasp carries no inputs for the edges a later one derives, so the first build after an upgrade is a full one; a route or worker added afterwards reaches every record on the next save.
- [ ] **Step 3:** `mix format --check-formatted` from `grasp/` (the rule), commit `Docs: an update resolves every record` plus trailer.
