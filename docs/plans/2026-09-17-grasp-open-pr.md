# Grasp Open-a-Pull-Request Recipe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Open PR 1212" typed in the chat panel (edit mode) checks the pull request's branch out in place, rebuilds the index against the PR's base, reloads the viewer and lays every changed flow out in its own frame.

**Architecture:** No new subsystem. The edit-mode allowlist admits `git fetch`, `git switch`, `gh pr view` and `gh pr checkout`; the system prompt carries the recipe with a hard dirty-tree rule; a `reload_index` MCP tool makes the store read the new file immediately.

**Tech Stack:** Elixir, anubis_mcp 2.0.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — §Chat panel (mode bullet and the "Open PR" bullet), Part 3 (`reload_index`), §Known gaps (milestone 5.4: "Opening a pull request switches the working tree").

## Global Constraints

- Public repo: no company, product or private project names beyond `SampleApp`; no local machine paths in docs.
- Every module `@moduledoc` (tool moduledocs are what agents read); public functions `@doc` + `@spec`; comments state durable facts, never history.
- Gates in `grasp/`: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (405 today). Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never run the real `claude` or `gh` CLI in tests.

---

### Task 1: The allowlist, the recipe and `reload_index`

**Files:** modify `grasp/lib/grasp/agent/command.ex`, `grasp/lib/grasp/mcp/server.ex`, `README.md` §Ask the agent; create `grasp/lib/grasp/mcp/tools/reload_index.ex`; tests `grasp/test/grasp/agent/command_test.exs`, `grasp/test/grasp/mcp/tools_test.exs` (or a new `reload_index_test.exs`), `grasp/test/grasp_web/mcp_test.exs` (tool name list).

**Requirements:**

- **Allowlist.** `@edit_allowed_tools` becomes exactly `mcp__grasp,Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(git status:*),Bash(git diff:*),Bash(git fetch:*),Bash(git switch:*),Bash(gh pr view:*),Bash(gh pr checkout:*)`. `@edit_tools` unchanged. Moduledoc: say why `git switch` and not `git checkout` (checkout also discards files; switch refuses to leave changes behind unless told to, which the prompt forbids).
- **`reload_index` tool** (`Grasp.MCP.Tools.ReloadIndex`, empty schema): calls `Grasp.IndexStore.reload/0`. On `:ok` replies `%{"path" => IndexStore.path(), "functions" => length(Index.functions(index)), "changed" => length(Index.changed_functions(index)), "base_ref" => git["base_ref"], "branch" => git["branch"], "head" => git["head"]}` (nulls when `index.git` is nil). On `{:error, :no_path}` → tool error `"no index path is being watched"`; on `{:error, reason}` → `"could not load the index: " <> inspect(reason)`. Moduledoc: when to call it (right after `mix grasp.index` finishes, before `list_changes`, so the file the rebuild replaced is never read). Register the component; add the name to the sorted list in `mcp_test.exs`.
- **System prompt.** In `system_prompt/3`, after the comments paragraph and before the closing, add a paragraph present in **both** modes that begins `When the user asks you to open, review or look at a pull request by number:` and, in `edit` mode, spells out the recipe as numbered steps: (1) `gh pr view N --json baseRefName,headRefName,title,url` to learn the base branch and the title; (2) `git status --porcelain` — if it prints anything, stop and tell the user the tree has uncommitted changes and which files, and do nothing else: never stash, reset, switch with `--discard-changes` or otherwise touch their work; (3) `gh pr checkout N`; (4) `git fetch origin <base>`; (5) rebuild the index from the project root with `mix grasp.index --base origin/<base>` plus the same `--out` the reindex command carries (derive it from the `reindex` argument: reuse its `--out` part, replace its `--base` part) ; (6) `reload_index`; (7) `list_changes`, then `set_cards` with roots at the entry points and one group per flow (title each group after what the flow does), and a two-sentence summary naming the PR title; also mention that comments left on an earlier branch stay in `.grasp/comments.json` until resolved. In `read` mode the paragraph is one sentence: say the chat must be switched to edit mode to check a branch out, and offer to review whatever branch is already indexed. Implement the `--out` reuse as a small pure function `reindex_against(reindex, base) :: String.t()` (`"mix grasp.index --base main --out x.json"`, `"origin/main"` → `"mix grasp.index --base origin/main --out x.json"`; a reindex without `--base` gains one) with `@doc`/`@spec` and tests.
- **README §Ask the agent.** A short paragraph after the edit-mode one: "Open PR 1212" — what the agent does, the dirty-tree rule, that `gh` must be installed and signed in, that the checkout happens in your working tree, and that the extra commands the allowlist admits are `git fetch`, `git switch`, `gh pr view` and `gh pr checkout`.
- **Tests.** `command_test.exs`: the edit argv's `--allowedTools` value equals the new string; the edit prompt contains `gh pr checkout` and `git status --porcelain`, the read prompt contains neither and does contain the switch-to-edit-mode sentence; `reindex_against/2` three cases. Tool test: `reload_index` on the test store (its watched path is the fixture) replies `functions` 22 (count `Index.functions/1` of the fixture rather than hard-coding), `base_ref` `"main"`, `changed` > 0; do not test the error path against the global store. `mcp_test.exs` name list updated.
- Gates; commit `Open a pull request from the chat: checkout in place, rebuild, reload`.
