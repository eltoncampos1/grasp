# Grasp Publish Comments and Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `publish_comments` MCP tool posts the review threads written in Grasp to the branch's pull request as GitHub review comments through `gh`, and `mix grasp.serve` runs from the reviewed project (a task of `grasp_index`) by launching the viewer from a checkout of this repository.

**Architecture:** `Grasp.GitHub` is the one module that shells out to `gh` (configurable command, a shell-script double in tests); `Grasp.GitHub.Diff` is a pure parser of a unified diff into the new-side line ranges GitHub accepts comments on; `Grasp.Comments.Publisher` decides per thread between a line comment and a file comment, posts, and stamps the thread's new `github` field through the store. The launcher is `Grasp.Index.Viewer` in `grasp_index`: pure resolution of the checkout and the steps it needs, commands run through an injected runner so tests never touch git or the network; the viewer's own task is renamed `mix grasp.viewer` so the two packages never define the same task module.

**Tech Stack:** Elixir / Phoenix LiveView, anubis_mcp 2.0, `gh` CLI.

**Spec:** `docs/specs/2026-09-15-grasp-design.md` — Part 2 opening (running the viewer), §Comments (Store `github` field, Publishing), Part 3 (`publish_comments`, `github_url`), §Chat panel ("Publish the comments" bullet), Known gaps (milestone 5.8).

## Global Constraints

- Public repo: no names beyond `SampleApp`/`acme` in code, tests, fixtures or docs. `@moduledoc`/`@doc`/`@spec` on everything public; HEEx `attr`; comments state durable facts, never history. UI state server-owned except the textarea draft and the canvas view/mode. CSS via the existing tokens.
- Tests never run the real `gh`, `git clone`, `mix deps.get` or the Claude CLI: `gh` is the script `grasp/test/support/fake_gh.sh` (config `:grasp, :gh_command` in `config/test.exs`), the launcher's commands go through an injected runner function.
- Gates: in `grasp/` — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix assets.build`, `mix test`; in `grasp_index/` — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`. Never `git add -A` (ExUnit `tmp_dir` writes under `grasp/tmp/`); add files by path. Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: `gh` wrapper, diff ranges, and the thread's `github` stamp

**Files:** create `grasp/lib/grasp/github.ex`, `grasp/lib/grasp/github/diff.ex`, `grasp/test/support/fake_gh.sh` (executable), `grasp/test/grasp/github_test.exs`, `grasp/test/grasp/github/diff_test.exs`; modify `grasp/lib/grasp/comments.ex`, `grasp/config/config.exs` (`gh_command: "gh"`), `grasp/config/test.exs` (`gh_command` → the script; `FAKE_GH_LOG` is not env — see below), `grasp/test/grasp/comments_test.exs`.

**Interfaces (produced):**

```elixir
# Grasp.GitHub — every call to gh goes through here. `root` is the project root (cwd for gh).
@type pull_request :: %{number: pos_integer(), url: String.t(), head_sha: String.t(), base_ref: String.t()}
@spec run([String.t()], Path.t()) :: {:ok, String.t()} | {:error, String.t()}
#   System.cmd(command, args, cd: root, stderr_to_stdout: true); command =
#   Application.get_env(:grasp, :gh_command, "gh"); a command System.find_executable/1 cannot
#   find → {:error, "gh is not installed or not on PATH"}; exit ≠ 0 → {:error, trimmed output}.
@spec pull_request(Path.t(), pos_integer() | nil) :: {:ok, pull_request()} | {:error, String.t()}
#   gh pr view [N] --json number,url,headRefOid,baseRefName  (N omitted → the current branch's PR)
@spec diff(Path.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
#   gh pr diff N
@spec create_review_comment(Path.t(), pos_integer(), map()) :: {:ok, %{id: pos_integer(), url: String.t()}} | {:error, String.t()}
#   gh api --method POST repos/{owner}/{repo}/pulls/N/comments -f body=… -f path=… -f commit_id=…
#   plus, for kind :line, -F line=N -f side=RIGHT; for kind :file, -f subject_type=file.
#   The map: %{body, path, commit_id, kind: :line | :file, line: pos_integer() | nil}.
#   Answer parsed from the JSON: "id" and "html_url".
@spec reply_review_comment(Path.t(), pos_integer(), pos_integer(), String.t()) :: {:ok, %{id: pos_integer(), url: String.t()}} | {:error, String.t()}
#   gh api --method POST repos/{owner}/{repo}/pulls/N/comments/ID/replies -f body=…

# Grasp.GitHub.Diff
@spec commentable_lines(String.t()) :: %{String.t() => [Range.t()]}
#   For each file section of a unified diff, the new-side path from `+++ b/PATH` (a `+++ /dev/null`
#   section — a deleted file — contributes nothing) mapped to one range per hunk taken from the
#   `@@ -a[,b] +c[,d] @@` header: c..(c + d - 1), with d defaulting to 1 and a d of 0 giving no range.

# Grasp.Comments
@type github :: %{id: pos_integer(), url: String.t(), published_at: String.t()}
# thread gains github: github() | nil (nil on add; build_thread sets nil)
@spec mark_published(pos_integer(), %{id: pos_integer(), url: String.t()}) :: {:ok, thread()} | {:error, :unknown}
#   sets github with published_at = now (ISO 8601 UTC, like created_at); broadcasts :comments_changed; persists.
#   encode_thread writes "github" => %{"id","url","published_at"} only when set; decode_thread reads it when
#   present and well-formed (integer id, binary url and published_at), nil when absent; a malformed
#   "github" makes the thread malformed (dropped like any other malformed entry).
```

**Requirements:**

- **`fake_gh.sh`.** A POSIX `sh` script standing in for `gh`. It appends its argv as one line to the file named by `FAKE_GH_LOG` when that variable is set (tests set it with `System.put_env` in a single `async: false` test module — see Task 2 — so this task's own tests do not rely on the log). Behaviour by argv:
  - `pr view --json …` (no number) → `{"number":42,"url":"https://github.com/acme/sample_app/pull/42","headRefOid":"0000000","baseRefName":"main"}`; `pr view N --json …` → the same with `N`, and `N` = 99 answers `headRefOid` `"9999999"` (for the head-mismatch warning). `pr view 404 …` → prints `no pull requests found for branch` to stderr and exits 1.
  - `pr diff N` → a diff with two sections: `lib/sample_app/greeter.ex` with one hunk `@@ -1,6 +1,8 @@` (new lines 1..8) and `lib/sample_app/formatter.ex` with `@@ -10,3 +10,4 @@` (new lines 10..13). Bodies of the hunks may be a few `+`/` ` lines; only the headers matter.
  - `api --method POST repos/{owner}/{repo}/pulls/N/comments …` → `{"id":<pid>,"html_url":"https://github.com/acme/sample_app/pull/N#discussion_r<pid>"}` where `<pid>` is `$$`; when the argv contains `GHFAIL` → prints `HTTP 422: Validation Failed (https://docs.github.com/rest)` and exits 1.
  - `api --method POST repos/{owner}/{repo}/pulls/N/comments/ID/replies …` → the same success shape.
  - Anything else → prints `fake gh: unexpected arguments` and exits 2.
- **`Grasp.GitHub.run/2`.** Exact behaviour in the interface block. `pull_request/2` decodes the JSON into the atom-keyed map above (`headRefOid` → `head_sha`, `baseRefName` → `base_ref`); a body that is not JSON of that shape → `{:error, "unexpected answer from gh pr view: …"}`.
- **Config.** `config/config.exs` gains `gh_command: "gh"` in the `:grasp` block; `config/test.exs` sets `gh_command: Path.expand("test/support/fake_gh.sh", __DIR__ <> "/..")` as `agent_command` does. `chmod +x` the script and commit the mode.
- **Tests.** `github_test.exs`: `pull_request(root, nil)` → number 42, head `"0000000"`; `pull_request(root, 404)` → `{:error, msg}` with `msg =~ "no pull requests"`; `create_review_comment` for a `:line` map → `{:ok, %{id: _, url: "https://github.com/acme/sample_app/pull/42#discussion_r" <> _}}`; with `body: "GHFAIL"` → `{:error, msg}` with `msg =~ "422"`; with `:grasp, :gh_command` pointed at a name that does not exist (use `Application.put_env` inside the test and restore in `on_exit`; mark the module `async: false` because of it) → `{:error, "gh is not installed or not on PATH"}`. `diff_test.exs`: the two-section diff from the script's text (paste the same text into the test as a heredoc — do not shell out) → `%{"lib/sample_app/greeter.ex" => [1..8], "lib/sample_app/formatter.ex" => [10..13]}`; a `+++ /dev/null` section yields no key; `@@ -3 +5 @@` yields `[5..5]`; `@@ -3,2 +5,0 @@` yields `[]`. `comments_test.exs`: `mark_published` on a thread → `github.id`, `github.url`, ISO 8601 `published_at`; encode → decode round-trips `github`; a thread without it decodes with `github: nil`; `mark_published(999, …)` → `{:error, :unknown}`.
- Gates; commit `Wrap gh and stamp published threads`.

---

### Task 2: `publish_comments`

**Files:** create `grasp/lib/grasp/comments/publisher.ex`, `grasp/lib/grasp/mcp/tools/publish_comments.ex`, `grasp/test/grasp/comments/publisher_test.exs`, `grasp/test/grasp/mcp/publish_comments_test.exs` (`async: false` — it sets `FAKE_GH_LOG`); modify `grasp/lib/grasp/mcp/server.ex` (register), `grasp/lib/grasp/mcp/comments.ex` (`"github_url"`), `grasp/lib/grasp/agent/command.ex` (prompt), `grasp/lib/grasp_web/components/comment_components.ex` + `grasp/assets/css/app.css` (footer link), README (§MCP tool list, §Ask the agent), tests `comment_tools_test.exs` (github_url null), `command_test.exs` (prompt sentence).

**Interfaces (consumed):** Task 1's `Grasp.GitHub`, `Grasp.GitHub.Diff.commentable_lines/1`, `Grasp.Comments.mark_published/2`, thread `github`.

**Interfaces (produced):**

```elixir
# Grasp.Comments.Publisher
@type report :: %{
  pull_request: %{number: pos_integer(), url: String.t()},
  published: [%{comment_id: pos_integer(), url: String.t(), kind: :line | :file}],
  skipped: [%{comment_id: pos_integer(), reason: String.t()}],
  failed: [%{comment_id: pos_integer(), error: String.t()}],
  warnings: [String.t()]
}
@spec publish(Grasp.Index.t(), keyword()) :: {:ok, report()} | {:error, String.t()}
# opts: pull_request: pos_integer() | nil (default nil), include_resolved: boolean (default false).
```

**Requirements:**

- **`publish/2`.** `root = index.project["root"]` (see how `Grasp.Comments` derives its path from the index's project root; reuse that lookup if it is a function, else read the same field). Not a directory on this machine → `{:error, "project root #{root} is not a directory on this machine"}`. Then `GitHub.pull_request(root, opts[:pull_request])`, `GitHub.diff(root, number)` → `ranges = Diff.commentable_lines/1`; either `gh` failure is the tool's `{:error, message}`. Threads: `Comments.list(include_resolved: opts[:include_resolved])` sorted by id. For each: `github != nil` → skipped `"already published"`; record missing from the index → failed `"function is no longer in the index"`; else build the comment:
  - `path = record["file"]`, `commit_id = pr.head_sha`.
  - **kind.** `:line` when `thread.side == "new"` and some range in `ranges[path]` contains `thread.line`; otherwise `:file`.
  - **body.** Author prefix `claude: ` when `thread.author == "agent"`, none for a human. For `:file`, the body is preceded by a location paragraph: `` `Mod.fun/2` · L12 `` for the new side, `` `Mod.fun/2` · deleted line 12 `` for the old side, then a blank line, then `> snippet` (omitted when `snippet` is nil), a blank line, then the (prefixed) body.
  - Post with `GitHub.create_review_comment/3`; on `{:error, e}` → failed with `e` and move on (no reply attempts). On success post each reply in order with `GitHub.reply_review_comment/4`, body prefixed `claude: ` for agent replies; a reply failure is appended to `warnings` as `"reply #{reply.id} of comment #{thread.id} was not posted: #{e}"` and does not undo the publish. Then `Comments.mark_published(thread.id, %{id, url})` and record `published`.
  - `warnings` starts with `"the index was built at #{index.git["head"]}, the pull request head is #{pr.head_sha}; line numbers may be off"` when `index.git` is present and the two differ (compare the pull request head prefix-insensitively: equal when one is a prefix of the other, so a short `head` in the index matches).
- **MCP tool `PublishComments`.** Schema: `pull_request` integer optional (description: the number; omitted → the current branch's pull request), `include_resolved` boolean default false. Executes `Publisher.publish/2` on `Tools.index()`; `{:ok, report}` is replied as JSON with string keys and `kind` as `"line"`/`"file"`; `{:error, msg}` → `Tools.error/2`. Register in `server.ex` after `ResolveComment`. `Grasp.MCP.Comments.thread_map/2` gains `"github_url" => thread.github && thread.github.url` (nil when unpublished).
- **Card.** In `comment_components.ex`, the thread footer shows `<a class="thread__github" href={url} target="_blank" rel="noopener">on GitHub</a>` when the thread is published; style it like the footer's other small controls (muted, underline on hover) using existing tokens. Read the component to find the footer with reply/resolve/delete and add the link beside them; the thread struct already reaches the component.
- **Prompt.** In `Grasp.Agent.Command.system_prompt/3`, after the comments paragraph (in both modes, since the tool is mode-independent), add: `When asked to publish, post or send the comments to the pull request, call publish_comments — with the number when the request names one — and report from its answer which threads went on their line, which went as file comments because GitHub's diff does not show that line, and any that failed. It skips threads it has already published.`
- **README.** §MCP: add `publish_comments(pull_request?, include_resolved?)` to the comments tool list with two sentences (line vs file comments, skips published). §Ask the agent: a paragraph "Publish the comments to PR 1212" — what happens, that it works in either mode, that `gh` must be installed and signed in.
- **Tests.** `publisher_test.exs` (`async: false`, sets `FAKE_GH_LOG` to a path under `@tag :tmp_dir` in `setup`, deletes the env var in `on_exit`; reads the fixture index with `Grasp.Index.load("test/fixtures/index.json")` — its project root is `/tmp/sample_app`, so `File.mkdir_p!` it in `setup`): a human thread on `SampleApp.Greeter.greet/2` new side at a line within 1..8 (check the fixture: greet/2's span — pick a line inside both the span and the hunk range; if the span starts after 8, add a thread with `Comments.add/2` on a line the span allows and adjust the script's hunk header in Task 1's file, keeping the two consistent) → `published` with `kind: :line`, the log line for `api` contains `side=RIGHT`, `line=<n>`, `commit_id=0000000`, and `path=lib/sample_app/greeter.ex`; the thread now has `github.url`; a second `publish` → the same id under `skipped` with `"already published"`. An agent thread on `SampleApp.Formatter.shout/1` at a line outside 10..13 → `kind: :file`, the log has `subject_type=file`, the body argument starts with `` `SampleApp.Formatter.shout/1` · L<n> `` and contains `claude: `. An old-side thread (on a modified function of the fixture — find one with `base_source`) → `:file` with `deleted line`. A thread with a reply → the log has a `/replies` call after the comment. A thread whose body is `GHFAIL` → in `failed` with `"422"`, not stamped. `pull_request: 404` → `{:error, msg =~ "no pull requests"}`. `pull_request: 99` → `warnings` has one entry mentioning `9999999`. Scope every assertion to the threads the test created (the store is shared). `publish_comments_test.exs`: the tool with no params replies JSON with `"pull_request" => %{"number" => 42, …}` and `published`/`skipped`/`failed`/`warnings` keys; error path with `pull_request: 404` is an `isError` response. `comment_tools_test.exs`: a freshly added thread lists `"github_url" => nil`. `command_test.exs`: both modes' prompts contain `publish_comments`.
- Gates; commit `Publish review comments to the pull request`.

---

### Task 3: `mix grasp.serve` from the reviewed project

**Files:** in `grasp_index/`: create `lib/grasp/index/viewer.ex`, `lib/mix/tasks/grasp.serve.ex`, `test/grasp/index/viewer_test.exs`; in `grasp/`: rename `lib/mix/tasks/grasp.serve.ex` → `lib/mix/tasks/grasp.viewer.ex` (`Mix.Tasks.Grasp.Viewer`, `mix grasp.viewer`, shortdoc "Serves the Grasp viewer for an index file; `mix grasp.serve` in the reviewed project runs it"), update any test naming the task; README §Quick start, §Layout if it names the task; spec already amended.

**Interfaces (produced):**

```elixir
# Grasp.Index.Viewer  (grasp_index)
@type runner :: ([String.t()], Path.t() -> non_neg_integer())
#   runs a command (argv, first element the executable) in a directory, streaming output, returns the exit status.
@type step :: {:clone, url :: String.t(), into :: Path.t()} | {:deps, project :: Path.t()} | {:assets, project :: Path.t()} | {:serve, project :: Path.t(), argv :: [String.t()]}
@spec checkout(keyword()) :: Path.t()
#   opts: viewer: Path.t() | nil, env: %{String.t() => String.t()}, cwd: Path.t(), cwd_app: atom() | nil
#   cwd_app == :grasp → cwd; else opts[:viewer] || env["GRASP_VIEWER"] || Path.expand("~/.grasp/viewer"); expanded.
@spec project(Path.t()) :: Path.t()
#   Path.join(checkout, "grasp") when "#{checkout}/grasp/mix.exs" exists, else checkout.
@spec steps(Path.t(), String.t(), [String.t()]) :: [step()]
#   checkout dir, repo url, viewer argv. Missing dir → [{:clone, url, dir}, {:deps, p}, {:assets, p}, {:serve, p, argv}]
#   with p = Path.join(dir, "grasp"); existing dir → p = project(dir); {:deps, p} when "#{p}/deps" is not a
#   directory; {:assets, p} when "#{p}/priv/static/assets/app.js" is not a file; always {:serve, p, argv} last.
@spec run([step()], runner()) :: :ok | {:error, String.t()}
#   {:clone, url, dir} → ["git", "clone", url, dir] in Path.dirname(dir) (created with File.mkdir_p!);
#   {:deps, p} → ["mix", "deps.get"] in p; {:assets, p} → ["mix", "assets.build"] in p;
#   {:serve, p, argv} → ["mix", "grasp.viewer" | argv] in p. A step whose status ≠ 0 stops the run with
#   {:error, "#{Enum.join(argv, " ")} failed with status N"}.
@spec default_repo() :: String.t()   # "https://github.com/gfrancischelli/grasp.git"
```

**Requirements:**

- **Task `Mix.Tasks.Grasp.Serve` (grasp_index).** `mix grasp.serve [--index PATH] [--viewer PATH] [--repo URL] [--port N] [--editor NAME] [--agent-command CMD] [--agent-model MODEL]`. Strict `OptionParser` with exactly those switches; unknown → `Mix.raise` listing them. `index = Path.expand(opts[:index] || ".grasp/index.json")`; not a regular file → `Mix.raise("grasp.serve: no index at #{index} — run mix grasp.index first")`. `repo = opts[:repo] || System.get_env("GRASP_VIEWER_REPO") || Viewer.default_repo()`. `checkout = Viewer.checkout(viewer: opts[:viewer], env: System.get_env(), cwd: File.cwd!(), cwd_app: Mix.Project.config()[:app])`. Viewer argv: `["--index", index | OptionParser.to_argv(Keyword.take(opts, [:port, :editor, :agent_command, :agent_model]))]`. Print one line per step before it runs (`Cloning the Grasp viewer into …`, `Fetching the viewer's dependencies…`, `Building the viewer's assets…`, `Starting the viewer from …`) through `Mix.shell().info/1`, then `Viewer.run(steps, runner)` with `runner = Application.get_env(:grasp_index, :viewer_runner, &Viewer.shell/2)`; `{:error, msg}` → `Mix.raise("grasp.serve: #{msg}")`.
- **`Viewer.shell/2`** (the real runner): `System.cmd(exe, args, cd: dir, into: IO.stream(), stderr_to_stdout: true, env: [{"MIX_ENV", "dev"}])` and return the status; `exe` not found on PATH → return 127 after printing `#{exe}: not found` (so the error names the tool). Document that Ctrl-C reaches the child because it shares the terminal's process group.
- **Viewer task rename (grasp/).** Move the module to `Mix.Tasks.Grasp.Viewer`, task name `grasp.viewer`, the `Mix.raise` prefixes `grasp.viewer:`; moduledoc first line says the launcher in the reviewed project runs it. `grep -rn "grasp.serve" grasp/ README.md docs/plans` and update every mention in `grasp/` and README to the new arrangement (README §Quick start: the dev-dep line, `mix deps.get && mix grasp.index`, then `mix grasp.serve --editor vscode` from the project, a sentence on `GRASP_VIEWER` for a local checkout and on the first-run clone; the "from this repo" block becomes `cd grasp && mix setup && mix grasp.viewer --index …` under a "Working on Grasp itself" note). Old plan files under `docs/plans/` are history and stay as they are.
- **Tests (`viewer_test.exs`, `async: true`, `@tag :tmp_dir`).** `checkout/1`: cwd_app `:grasp` → cwd; `viewer:` beats env; env `GRASP_VIEWER` beats the default; default ends in `.grasp/viewer`. `project/1`: a tmp checkout with `grasp/mix.exs` → the `grasp` subdir; without → itself. `steps/3`: missing dir → clone, deps, assets, serve in that order with `p = dir/grasp`; a tmp checkout with `grasp/mix.exs`, `grasp/deps/` and `grasp/priv/static/assets/app.js` → `[{:serve, p, argv}]` only; without `deps/` → deps then serve; without the built asset → assets then serve. `run/2` with a runner that records `{argv, dir}` into an `Agent` and returns 0 → the recorded commands are `["git","clone",url,dir]` in the parent dir, `["mix","deps.get"]`, `["mix","assets.build"]`, `["mix","grasp.viewer","--index",…]` in `p`; a runner returning 1 on `deps.get` → `{:error, "mix deps.get failed with status 1"}` and the serve command was never recorded. The Mix task: `Mix.Tasks.Grasp.Serve.run(["--index", missing])` raises `Mix.Error` matching `run mix grasp.index first`; with `Application.put_env(:grasp_index, :viewer_runner, recording_fun)` (restore in `on_exit`; this one test module part `async: false`, or keep the task test in its own `async: false` file `test/mix/tasks/grasp.serve_test.exs`) and `--viewer` at a ready tmp checkout and a real tmp index file → the recorded serve argv carries `--index <abs>` and `--editor vscode` when given.
- Gates in both projects. In `grasp/`, `mix grasp.viewer --index test/fixtures/index.json` is not run in tests (it starts the server); the rename is verified by `mix help grasp.viewer` in the implementer's report. Commit `Run the viewer from the reviewed project with mix grasp.serve`.
