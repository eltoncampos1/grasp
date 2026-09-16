defmodule Grasp.Agent.Command do
  @moduledoc """
  Builds the argv that runs the Claude Code CLI headless against this viewer.

  The CLI is asked for `stream-json` on stdout so the runner can render a transcript as it
  arrives, and is pointed at the viewer's own `/mcp` endpoint with an inline
  `--mcp-config`. `--strict-mcp-config` keeps the developer's own `.mcp.json` out of the
  run, and the tool allowlist keeps the agent to reading: the grasp tools plus `Read`,
  `Grep` and `Glob`, with nothing that writes files or runs commands.

  The system prompt names the viewer session the agent is driving; every grasp card tool
  takes that session, so an agent that forgets it would arrange cards on a canvas nobody is
  looking at. It also tells the agent that the canvas is a graph: a function reached from
  two callers is one card with an edge from each, so the same key is reused rather than the
  function being described twice.
  """

  alias Grasp.IndexStore

  @default_port 4040
  @max_turns "60"
  @tools "Read,Grep,Glob"
  @allowed_tools "mcp__grasp,Read,Grep,Glob"

  @type option ::
          {:command, String.t()}
          | {:session, String.t()}
          | {:mcp_url, String.t()}
          | {:resume, String.t() | nil}
          | {:model, String.t() | nil}

  @doc """
  The command and argv that run `prompt` for one turn of the conversation.

  `:resume` continues the CLI session of a previous run, so the agent keeps the context it
  built up; `:model` overrides the CLI's default model.
  """
  @spec build(String.t(), [option()]) :: {String.t(), [String.t()]}
  def build(prompt, opts) do
    session = Keyword.fetch!(opts, :session)
    mcp_url = Keyword.fetch!(opts, :mcp_url)

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
        @tools,
        "--allowedTools",
        @allowed_tools,
        "--max-turns",
        @max_turns,
        "--append-system-prompt",
        system_prompt(session)
      ] ++
        flag("--resume", opts[:resume]) ++ flag("--model", opts[:model])

    {Keyword.fetch!(opts, :command), argv}
  end

  @doc "The instructions the agent runs under, naming the viewer session it drives."
  @spec system_prompt(String.t()) :: String.t()
  def system_prompt(session) do
    """
    You are the review assistant inside Grasp, a call-chain code review tool. The user is looking at a canvas of function cards; your job is to arrange those cards so a flow is easy to read, and to explain briefly.

    The Grasp viewer session you control is "#{session}". Pass session: "#{session}" to every grasp card tool.

    Work like this:
    1. Discover with the grasp read tools: search_functions, get_function, get_callers, get_callees, list_entry_points, find_paths (with only `to` it walks callers back to entry points such as controller actions, LiveView callbacks and Oban workers).
    2. Answer with set_cards: one call that lays out the whole flow, roots at the entry points, each callee under the function that calls it, in call order. The same function reached from two callers is one card with two edges — reuse the key. Add a highlight on a card when one call or line range is the point of interest.
    3. Reply in a few sentences: what the flow does and where to look first. The cards are the answer; do not paste source code.

    Do not edit files or run commands. If a function is not in the index, say so.
    """
    |> String.trim_trailing()
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

  defp mcp_config(url),
    do: Jason.encode!(%{"mcpServers" => %{"grasp" => %{"type" => "http", "url" => url}}})

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, value]
end
