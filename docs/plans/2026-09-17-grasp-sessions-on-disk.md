# Grasp Sessions on Disk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A review session survives a viewer restart: every mutation is written, coalesced, to `<project.root>/.grasp/sessions/<name>.json`, a session starting up reads its file back (dropping cards whose functions left the index), the sidebar header names the session and opens a menu to switch, create and delete sessions, and `list_sessions` names saved sessions too.

**Architecture:** `Grasp.Session.Forest` gains `dump/1` and `load/2` (the struct to and from string-keyed maps, `load/2` pruning against the index). `Grasp.Session.Disk` owns the file: path resolution (`:grasp, :sessions_dir` override, else the index's project root when it is a directory, else nil for memory only), read with corrupt-file salvage, write, delete and the list of saved names. `Grasp.Session` (the GenServer) loads in `init/1`, schedules one coalesced write per burst of mutations, flushes in `terminate/2`, and grows `delete/1`; `list/0` unions running and saved. The sidebar header gets the session menu; `ReviewLive` handles the navigation events and a `:session_deleted` broadcast.

**Tech Stack:** Elixir / Phoenix LiveView.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — §Session (persistence paragraph), §Page (sidebar header session menu), Part 3 (`list_sessions`), Milestones (6).

## Global Constraints

- Public repo: no names beyond `SampleApp`/`acme` in code, tests, fixtures or docs. `@moduledoc`/`@doc`/`@spec` on everything public; HEEx `attr`; comments state durable facts, never history. UI state server-owned except the textarea draft and the canvas view/mode. CSS via the existing tokens.
- The fixture index (`grasp/test/fixtures/index.json`) names a project root that does not exist on disk, so tests must set `:grasp, :sessions_dir` in `config/test.exs` to a per-run temporary directory (as `comments_path` is), and tests that need isolation use `@tag :tmp_dir` with `Application.put_env` only in `async: false` modules, restored in `on_exit`.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test`. Never `git add -A` (ExUnit `tmp_dir` writes under `grasp/tmp/`); add files by path. Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: Dump, load, and the file behind a session

**Files:** create `grasp/lib/grasp/session/disk.ex`, `grasp/test/grasp/session/disk_test.exs`; modify `grasp/lib/grasp/session/forest.ex`, `grasp/lib/grasp/session.ex`, `grasp/lib/grasp/mcp/tools/list_sessions.ex` (moduledoc only), `grasp/config/config.exs` (`sessions_dir: nil`), `grasp/config/test.exs`, `grasp/test/grasp/session/forest_test.exs`, `grasp/test/grasp/session_test.exs` (create if absent), README §MCP (`list_sessions` wording), spec is already amended.

**Interfaces (produced):**

```elixir
# Grasp.Session.Forest
@spec dump(t()) :: map()
#   %{"version" => 1, "cards" => [card_map], "edges" => [edge_map], "groups" => [group_map],
#     "focus" => id | nil, "next_id" => n, "next_color" => n, "next_group" => n}
#   card_map: %{"id","function_id","collapsed","offset" => [dx, dy],"highlight","view","context","group"}
#     (view/context as strings; highlight as stored, already string-keyed or nil)
#   edge_map: %{"from","to","target","color"}; group_map: %{"id","title"}; lists in id order.
@spec load(map(), Grasp.Index.t() | nil) :: {:ok, t()} | :error
#   :error for a map that is not "version" => 1 or whose fields do not decode (ids not positive
#   integers, view/context not one of the known strings, offset not two integers, edges naming
#   unknown cards, groups referenced by a card but absent). With an index, a card whose
#   function_id Grasp.Index.fetch_function/2 does not find is dropped with its edges, and a
#   group no card references afterwards is dropped; focus falls back to the lowest remaining card
#   id (nil when none). Counters are kept as dumped (never lowered), so ids are never reused.
#   With nil no pruning happens.

# Grasp.Session.Disk
@spec dir() :: Path.t() | nil
#   Application.get_env(:grasp, :sessions_dir) when set; else "<index.project.root>/.grasp/sessions"
#   when Grasp.IndexStore.get() is an index whose root is a directory on this machine; else nil.
@spec path(String.t()) :: Path.t() | nil          # Path.join(dir(), name <> ".json") or nil
@spec read(String.t(), Grasp.Index.t() | nil) :: {:ok, Grasp.Session.Forest.t()} | :empty | {:error, term()}
#   :empty when there is no dir or no file. A file that does not parse as JSON, or whose map
#   Forest.load/2 rejects, is renamed to "<name>.json.corrupt" (a timestamp suffix when that
#   exists) and {:error, {:corrupt, moved_to}} is returned; the caller logs and starts empty.
@spec write(String.t(), Grasp.Session.Forest.t()) :: :ok | {:error, term()}
#   mkdir_p the dir, write Jason.encode!(dump, pretty: true) to a temp file beside it and rename
#   over the target, so a crash mid-write never leaves a half file. :ok when dir() is nil.
@spec delete(String.t()) :: :ok                    # rm the file if present; :ok when no dir
@spec saved() :: [String.t()]                      # basenames without .json, sorted; [] when no dir
@spec valid_name?(String.t()) :: boolean()         # ~r/^[A-Za-z0-9_-]{1,40}$/

# Grasp.Session
# init/1: forest = case Disk.read(name, Grasp.IndexStore.get()) do {:ok, f} -> f; :empty -> Forest.new();
#   {:error, reason} -> Logger.warning(...); Forest.new() end. Process.flag(:trap_exit, true) so terminate runs.
# every successful mutation (mutate and replace) sets state.dirty = true and, when no timer is
#   pending, Process.send_after(self(), :flush, 150); handle_info(:flush) writes when dirty and clears
#   the timer. terminate/2 writes when dirty. The write goes through Disk.write/2; a failure is logged.
@spec delete(name()) :: :ok
#   stops the running process if any (GenServer.stop(via(name)) after broadcasting {:session_deleted, name}
#   on the session's topic — the broadcast goes first so a tab can leave before the process is gone),
#   then Disk.delete(name). Deleting "default" is allowed: it clears the canvas.
@spec list() :: [String.t()]                       # running ∪ Disk.saved(), sorted, unique
```

**Requirements:**

- **Debounce semantics.** One timer at a time: a mutation while a timer is pending does not reschedule it, so a drag writing 60 moves a second lands at most every 150 ms. Stopping the session (supervisor shutdown, `delete/1`) flushes. A write happens only when the forest changed since the last write.
- **`:index_reloaded`.** Not handled in this task; a card of a vanished function stays until the next restart, when `load/2` prunes it. (Say so in the Session moduledoc.)
- **Config.** `config.exs` gains `sessions_dir: nil`; `test.exs` sets `sessions_dir: Path.join(System.tmp_dir!(), "grasp-test-sessions-#{System.os_time(:millisecond)}")`.
- **Tests.** `forest_test.exs`: `dump/1` then `load/2` with nil index round-trips a forest with two grouped cards, an edge, a moved card (offset), a highlight, a non-default view and context, and preserves counters; `load/2` with the fixture index drops a card whose function is `"Gone.away/0"` along with its edge and its now-empty group and moves focus; version 2 → `:error`; a card with view `"sideways"` → `:error`. `disk_test.exs` (`async: false`, sets `:sessions_dir` to `tmp_dir` and restores): `read` of a missing file → `:empty`; `write` then `read` round-trip; a file containing `not json` → `{:error, {:corrupt, path}}` and the file now sits at `<name>.json.corrupt`; `saved/0` lists written names sorted; `delete/1` removes; `valid_name?` accepts `review-1`, rejects `../x`, `""`, a 41-character name. `session_test.exs` (`async: false`, own `:sessions_dir`): open a card in session `"disk-#{unique}"`, wait for the file (poll up to 1 s), stop the process with `GenServer.stop`, `Session.ensure` again and `Session.get` shows the card with the same id; `Session.list/0` includes a saved-but-not-running name; `delete/1` removes the file and a subscriber receives `{:session_deleted, name}`; two mutations within 150 ms produce one write (count `File.stat` mtime changes or wrap: assert the file does not exist right after the first mutation and exists after 300 ms).
- README §MCP: `list_sessions()` — "the review sessions the viewer is running or has saved".
- Gates; commit `Sessions persist beside the index`.

---

### Task 2: The session menu

**Files:** modify `grasp/lib/grasp_web/components/sidebar.ex` (header), `grasp/lib/grasp_web/live/review_live.ex` (assigns `session_name`, `sessions`, `session_menu_open`; events; `:session_deleted`), `grasp/assets/css/app.css`, README (§Gestures or a new §Sessions paragraph; §Quick start one line on `.grasp/sessions/`), tests `grasp/test/grasp_web/live/review_live_test.exs` or a new `sessions_live_test.exs` (`async: false` because it deletes sessions and reads the disk).

**Interfaces (consumed):** Task 1's `Grasp.Session.list/0`, `delete/1`, `Grasp.Session.Disk.valid_name?/1`.

**Requirements:**

- **Header.** At the top of the sidebar, above the entry-point groups: `<button id="session-menu" class="session" phx-click="toggle_session_menu" aria-expanded={@session_menu_open}>` reading the session name (`default` shown as `default`) with a small chevron. When open, a `<div class="session__menu">` lists `Grasp.Session.list/0`: each row a `<.link navigate={path}>` (`/` for `default`, `/s/#{name}` otherwise) with the current one marked `aria-current="true"`, and for every row but the current a `<button phx-click="delete_session" phx-value-name={name} data-confirm={"Delete session #{name}? Its cards are forgotten."}>` (×). Under the list, a form `<form phx-submit="new_session"><input name="name" placeholder="new session" autocomplete="off" /></form>`; a valid name → `push_navigate` to its path (existing or not — `Session.ensure` in `mount` creates it); an invalid one → `put_flash(:error, "a session name is letters, digits, - and _, up to 40")` and the input keeps its value (server-owned `new_session_name` assign).
- **Events.** `toggle_session_menu`; `new_session` (`%{"name" => name}`); `delete_session` (`%{"name" => name}`) → `Session.delete(name)`, then `sessions` recomputed. The list `sessions` is computed at mount, when the menu opens, and after a delete — not on every render. Handle `{:session_deleted, name}` from the subscribed topic: when it names this tab's session, `push_navigate(to: "/")` (from `default` itself, `push_navigate` to `/` re-mounts an empty default). Escape closes the menu (extend `close_overlays/1`).
- **CSS.** `.session` a full-width header row using the sidebar's existing type scale and border tokens; `.session__menu` a popover below it (`position: absolute` within the sidebar, `--bg`, `--border`, `--radius` tokens), rows as flex with the × at the end, `aria-current` row bold. No new colours.
- **Tests.** Mount `/s/menu-#{unique}`; the header reads the name; `toggle_session_menu` shows the menu with the current row `aria-current`; `new_session` with `"review-1"` → `assert_redirect`/`assert_push_navigate` to `/s/review-1` (LiveViewTest: `{:error, {:live_redirect, %{to: "/s/review-1"}}}` from `render_submit`); with `"../x"` → the flash text and no redirect; after opening a card in another session `"other-#{unique}"` (via `Grasp.Session.open_root`) it appears in the list; `delete_session` on it removes it from the list and `Grasp.Session.Disk.read(name, nil)` is `:empty`; a tab on a session that gets deleted receives the navigate (`assert_redirect` after `Session.delete/1` from the test process).
- README: a §Sessions paragraph — where the files are, that `default` is the canvas at `/`, the menu, that `.grasp/index.json` is worth gitignoring while `.grasp/sessions/` and `.grasp/comments.json` can travel with a branch.
- Gates; commit `A session menu in the sidebar`.
