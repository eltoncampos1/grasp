defmodule Grasp.Agent.Command do
  @moduledoc """
  Builds the argv that runs the Claude Code CLI headless against this viewer.

  The CLI is asked for `stream-json` on stdout so the runner can render a transcript as it
  arrives, and is pointed at the viewer's own `/mcp` endpoint with an inline
  `--mcp-config`. `--strict-mcp-config` keeps the developer's own `.mcp.json` out of the
  run, and the tool allowlist follows the chat's mode. In `read` mode it is the grasp tools
  plus `Read`, `Grep` and `Glob`, with nothing that writes files or runs commands. In `edit`
  mode it also carries `Edit`, `Write` and a `Bash` narrowed to `mix`, to the read-only git
  commands, to `git fetch` and `git switch`, and to the two `gh` subcommands that read a pull
  request and check it out, so the agent can act on a review comment, rebuild the index and
  put a pull request's branch in the working tree, and still cannot reach for an arbitrary
  shell command. The branch-changing command is `git switch` rather than `git checkout`:
  checkout also discards files, while switch refuses to leave uncommitted changes behind
  unless it is told to — and the prompt forbids telling it to.

  The system prompt names the viewer session the agent is driving; every grasp card tool
  takes that session, so an agent that forgets it would arrange cards on a canvas nobody is
  looking at. It also tells the agent that the canvas is a graph: a function reached from
  two callers is one card with an edge from each, so the same key is reused rather than the
  function being described twice, and that a question about a change starts from the list
  of changed functions rather than from a search. Several flows asked for at once become
  one group per flow, so each is framed and titled on the canvas instead of running into
  its neighbour. A pull request asked for by number has its own recipe — check the branch
  out, rebuild the index against the pull request's base, reload it, then lay the change
  out — which `edit` mode spells out step by step and `read` mode answers with the one
  sentence that sends the user to the mode that can run it. It closes on the mode: what
  `read` refuses, and what `edit` owes the canvas after an edit — a format, a rebuilt index,
  and cards laid out over the code as it now is.
  """

  alias Grasp.Index
  alias Grasp.IndexStore

  @default_port 4040
  @max_turns "60"
  @read_tools "Read,Grep,Glob"
  @read_allowed_tools "mcp__grasp,Read,Grep,Glob"
  @edit_tools "Read,Grep,Glob,Edit,Write,Bash"
  @edit_allowed_tools "mcp__grasp,Read,Grep,Glob,Edit,Write,Bash(mix:*),Bash(git status:*),Bash(git diff:*),Bash(git fetch:*),Bash(git switch:*),Bash(gh pr view:*),Bash(gh pr checkout:*)"

  @type option ::
          {:command, String.t()}
          | {:session, String.t()}
          | {:mcp_url, String.t()}
          | {:resume, String.t() | nil}
          | {:model, String.t() | nil}
          | {:mode, String.t()}
          | {:reindex, String.t()}

  @doc """
  The command and argv that run `prompt` for one turn of the conversation.

  `:resume` continues the CLI session of a previous run, so the agent keeps the context it
  built up; `:model` overrides the CLI's default model. `:mode` is `"read"` (the default) or
  `"edit"`, and picks both the tools the CLI is given and the closing paragraph of the
  system prompt; `:reindex` is the index-rebuilding command that paragraph spells out, as
  `reindex_command/2` writes it.
  """
  @spec build(String.t(), [option()]) :: {String.t(), [String.t()]}
  def build(prompt, opts) do
    session = Keyword.fetch!(opts, :session)
    mcp_url = Keyword.fetch!(opts, :mcp_url)
    mode = Keyword.get(opts, :mode) || "read"
    reindex = Keyword.get(opts, :reindex) || reindex_command(nil, nil)

    argv =
      [
        "-p",
        prompt,
        "--output-format",
        "stream-json",
        "--verbose",
        "--strict-mcp-config",
        "--mcp-config",
        mcp_config(mcp_url),
        "--tools",
        tools(mode),
        "--allowedTools",
        allowed_tools(mode),
        "--max-turns",
        @max_turns,
        "--append-system-prompt",
        system_prompt(session, mode, reindex)
      ] ++
        flag("--resume", opts[:resume]) ++ flag("--model", opts[:model])

    {Keyword.fetch!(opts, :command), argv}
  end

  @doc """
  The instructions the agent runs under, naming the viewer session it drives.

  `mode` is `"read"` or `"edit"`; `reindex` is the command the edit-mode closing tells the
  agent to rebuild the index with.
  """
  @spec system_prompt(String.t(), String.t(), String.t()) :: String.t()
  def system_prompt(session, mode, reindex) do
    """
    You are the review assistant inside Grasp, a call-chain code review tool. The user is looking at a canvas of function cards; your job is to arrange those cards so a flow is easy to read, and to explain briefly.

    The Grasp viewer session you control is "#{session}". Pass session: "#{session}" to every grasp card tool.

    Work like this:
    1. Discover with the grasp read tools: search_functions, get_function, get_callers, get_callees, list_entry_points, find_paths (with only `to` it walks callers back to entry points such as controller actions, LiveView callbacks and Oban workers). For questions about what a change does, start from list_changes and trace each changed function to its entry points with find_paths.
    2. Answer with set_cards: one call that lays out the whole flow, roots at the entry points, each callee under the function that calls it, in call order. The same function reached from two callers is one card with two edges — reuse the key. Add a highlight on a card when one call or line range is the point of interest. When the user asks for several flows at once, give each flow its own group: put the flow's name in the `group` field of every card that belongs to it, so the canvas draws each flow in its own titled frame.
    3. Reply in a few sentences: what the flow does and where to look first. The cards are the answer; do not paste source code. If a function is not in the index, say so.

    The reviewer leaves comments on lines of the cards, the way review comments are left on a pull request. list_comments returns the open ones: the function each thread sits on, the line and the text of that line, the body and the replies. When you are asked to address, answer or handle the comments, take them one at a time — read what the thread points at with get_function or Read, act on what it asks, then reply_comment with one or two sentences on what you did and resolve_comment to close it. add_comment leaves a remark of your own on a line worth the reviewer's attention.

    #{pull_request(mode, reindex)}

    #{closing(mode, reindex)}
    """
    |> String.trim_trailing()
  end

  @doc """
  The command that rebuilds `index` from the project root, as the edit-mode prompt spells
  it out.

  The base ref the index was built against is repeated so the rebuilt index still knows
  which functions the branch changed, and `--out` is added whenever the viewer watches a
  path other than the default `.grasp/index.json` under the root — a rebuild that wrote
  somewhere else would leave the viewer showing the code as it read before the edit.
  """
  @spec reindex_command(Index.t() | nil, String.t() | nil) :: String.t()
  def reindex_command(index, watched_path)

  def reindex_command(nil, _watched_path), do: "mix grasp.index"

  def reindex_command(%Index{} = index, watched_path) do
    base =
      case index.git["base_ref"] do
        ref when is_binary(ref) -> " --base #{ref}"
        _no_base -> ""
      end

    "mix grasp.index" <> base <> out(index.project["root"], watched_path)
  end

  @doc """
  `reindex` rebuilt against `base` instead of the ref the index carries.

  The `--out` the viewer's own reindex command names is kept, so a rebuild for a pull
  request still writes the file the viewer watches; only the base ref changes, and a
  command with no `--base` at all gains one.
  """
  @spec reindex_against(String.t(), String.t()) :: String.t()
  def reindex_against(reindex, base) when is_binary(reindex) and is_binary(base) do
    out =
      case Regex.run(~r/--out\s+(\S+)/, reindex) do
        [_match, path] -> " --out #{path}"
        nil -> ""
      end

    "mix grasp.index --base #{base}" <> out
  end

  @doc "The URL of this viewer's MCP endpoint, on the loopback address the endpoint serves."
  @spec mcp_url() :: String.t()
  def mcp_url do
    # `http: false` is a legal endpoint setting for a node that only runs the MCP client side.
    port =
      case Application.get_env(:grasp, GraspWeb.Endpoint, [])[:http] do
        http when is_list(http) -> Keyword.get(http, :port, @default_port)
        _not_serving -> @default_port
      end

    "http://127.0.0.1:#{port}/mcp"
  end

  @doc """
  The directory the CLI runs in: the root of the indexed project, so `Read` and `Grep`
  resolve the paths the index records, or the viewer's own directory when that root is
  not on this machine.
  """
  @spec cwd() :: String.t()
  def cwd do
    index = IndexStore.get()
    root = index && index.project["root"]

    if is_binary(root) and File.dir?(root), do: root, else: File.cwd!()
  end

  defp tools("edit"), do: @edit_tools
  defp tools(_read), do: @read_tools

  defp allowed_tools("edit"), do: @edit_allowed_tools
  defp allowed_tools(_read), do: @read_allowed_tools

  defp pull_request("edit", reindex) do
    """
    When the user asks you to open, review or look at a pull request by number:
    1. Run `gh pr view N --json baseRefName,headRefName,title,url` to learn the base branch the pull request targets and its title.
    2. Run `git status --porcelain`. If it prints anything, stop: tell the user the working tree has uncommitted changes, name the files it listed, and do nothing else. Never stash, reset, pass `--discard-changes`, `-f` or `--force` to git, or otherwise touch their work.
    3. Run `gh pr checkout N`. The branch is checked out in the user's own working tree, not a copy.
    4. Run `git fetch origin <base>` for the base branch you read in step 1, so the ref the index compares against is on this machine.
    5. Rebuild the index from the project root with `#{reindex_against(reindex, "origin/<base>")}`. If mix reports that the task does not exist, the checked-out branch does not carry grasp_index as a dependency: stop and tell the user, since the cards cannot follow a branch that cannot be indexed.
    6. Call reload_index, so what you read next is the index the rebuild wrote rather than the one it replaced.
    7. Call list_changes, trace each changed function back to its entry points with find_paths, then call set_cards with the roots at the entry points and one group per flow, each group titled after what that flow does. Reply in two sentences that name the pull request's title.
    Comments stay in `.grasp/comments.json` until they are resolved, so list_comments can answer with threads left on a branch other than the one now checked out.
    """
    |> String.trim_trailing()
  end

  defp pull_request(_read, _reindex) do
    "When the user asks you to open, review or look at a pull request by number: the chat has to be switched to edit mode before a branch can be checked out, so say that, and offer to review whatever branch is already indexed."
  end

  defp closing("edit", reindex) do
    "You may edit files under the project root and run mix. After editing: run `mix format` on the files you touched; rebuild the index from the project root with `#{reindex}` — the viewer reloads the cards from it within a couple of seconds; then arrange the cards again (set_cards or highlight_card) so the diagram shows the code as it now is. Keep every change to what the comments ask for, and say what you changed."
  end

  defp closing(_read, _reindex) do
    "Do not edit files or run commands — this chat is in read mode. When a comment asks for a code change, reply with the change you would make and tell the user to switch the chat to edit mode."
  end

  defp out(_root, nil), do: ""

  defp out(root, watched_path) when is_binary(root) do
    path = Path.expand(watched_path)

    if path == Path.join(Path.expand(root), ".grasp/index.json"),
      do: "",
      else: " --out #{Path.relative_to(path, Path.expand(root))}"
  end

  defp out(_root, watched_path), do: " --out #{Path.expand(watched_path)}"

  defp mcp_config(url),
    do: Jason.encode!(%{"mcpServers" => %{"grasp" => %{"type" => "http", "url" => url}}})

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, value]
end
