defmodule Grasp.Agent.Stream do
  @moduledoc """
  Folds the Claude Code CLI's `--output-format stream-json` output into a transcript.

  The CLI writes one JSON object per line: a `system`/`init` announcing the CLI session id
  and the MCP servers it managed to reach, `assistant` and `user` messages carrying content
  blocks, and a final `result`. This module turns that sequence into the flat list of
  entries the viewer renders, oldest first, and is pure: the runner owns the port, this owns
  the meaning of what comes out of it.

  Tool calls are two events apart — an `assistant` block starts one, a later `user` block
  reports it — so a tool entry is appended `:running` and closed when its result arrives.
  The result carries the id of the call it answers, but a transcript only ever shows tool
  calls in the order they were made, so the oldest running entry is the one to close.

  A line that is not JSON goes to `log` rather than the transcript: with the port merging
  stderr into stdout, that is where a crash report or a CLI warning shows up, and dropping
  it would leave a failed run with nothing to explain it.
  """

  @type entry ::
          %{type: :user, text: String.t()}
          | %{type: :assistant, text: String.t()}
          | %{
              type: :tool,
              name: String.t(),
              summary: String.t(),
              status: :running | :done | :error
            }
          | %{type: :error, text: String.t()}
          | %{type: :done, cost_usd: float() | nil, turns: integer() | nil}

  @type t :: %{
          entries: [entry()],
          claude_session_id: String.t() | nil,
          log: [String.t()],
          done?: boolean(),
          result_text: String.t() | nil
        }

  @summary_keys ~w(query id to function_id file_path pattern)

  @doc "An empty transcript."
  @spec new() :: t()
  def new,
    do: %{entries: [], claude_session_id: nil, log: [], done?: false, result_text: nil}

  @doc """
  Folds one line of CLI output into `state`.

  A blank line is ignored, a line that does not decode as a JSON object is logged, and an
  event of an unknown type (or a `rate_limit_event`) leaves the state untouched.
  """
  @spec apply(t(), String.t()) :: t()
  def apply(state, line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = event} -> event(state, event["type"], event)
      _ -> log(state, line)
    end
  end

  @doc """
  Appends the prompt the user typed and clears what the previous run concluded, so the
  transcript grows across runs while `done?` and `result_text` describe only the run that
  is starting.
  """
  @spec prompt(t(), String.t()) :: t()
  def prompt(state, text),
    do: %{append(state, %{type: :user, text: text}) | done?: false, result_text: nil}

  @doc "Appends an error the runner noticed rather than the CLI reported."
  @spec error(t(), String.t()) :: t()
  def error(state, text), do: append(state, %{type: :error, text: text})

  defp log(state, line) do
    case String.trim(line) do
      "" -> state
      trimmed -> %{state | log: state.log ++ [trimmed]}
    end
  end

  defp event(state, "system", %{"subtype" => "init"} = event) do
    state
    |> Map.put(:claude_session_id, event["session_id"] || state.claude_session_id)
    |> check_mcp(event["mcp_servers"])
  end

  defp event(state, "assistant", event) do
    event
    |> content()
    |> Enum.reduce(state, &block/2)
  end

  defp event(state, "user", event) do
    event
    |> content()
    |> Enum.reduce(state, &block/2)
  end

  defp event(state, "result", event) do
    state = %{state | done?: true, result_text: event["result"]}

    state =
      if event["is_error"] do
        error(state, event["result"] || event["subtype"])
      else
        state
      end

    append(state, %{type: :done, cost_usd: event["total_cost_usd"], turns: event["num_turns"]})
  end

  defp event(state, _type, _event), do: state

  defp content(%{"message" => %{"content" => blocks}}) when is_list(blocks), do: blocks
  defp content(_event), do: []

  defp block(%{"type" => "text", "text" => text}, state), do: assistant(state, text)

  defp block(%{"type" => "tool_use"} = block, state) do
    input = block["input"] || %{}

    append(state, %{
      type: :tool,
      name: String.replace_prefix(block["name"] || "", "mcp__grasp__", ""),
      summary: summary(input),
      status: :running
    })
  end

  defp block(%{"type" => "tool_result"} = block, state) do
    status = if block["is_error"], do: :error, else: :done
    close_oldest_running(state, status)
  end

  defp block(_block, state), do: state

  defp summary(input) when is_map(input) do
    cond do
      value = Enum.find_value(@summary_keys, &printable(input[&1])) -> value
      is_list(input["cards"]) -> "#{length(input["cards"])} cards"
      true -> ""
    end
  end

  defp summary(_input), do: ""

  defp printable(value) when is_binary(value), do: value != "" && value
  defp printable(value) when is_number(value), do: to_string(value)
  defp printable(_value), do: nil

  defp check_mcp(state, servers) when is_list(servers) do
    case Enum.find(servers, &(is_map(&1) and &1["name"] == "grasp")) do
      %{"status" => "connected"} ->
        state

      server ->
        status = (is_map(server) && server["status"]) || "missing"
        append(state, %{type: :error, text: "grasp MCP server not connected (status: #{status})"})
    end
  end

  defp check_mcp(state, _servers), do: check_mcp(state, [])

  defp assistant(state, text) do
    case List.last(state.entries) do
      %{type: :assistant, text: previous} ->
        %{
          state
          | entries:
              List.replace_at(state.entries, -1, %{type: :assistant, text: previous <> text})
        }

      _ ->
        append(state, %{type: :assistant, text: text})
    end
  end

  defp close_oldest_running(state, status) do
    case Enum.find_index(state.entries, &(&1.type == :tool and &1.status == :running)) do
      nil ->
        state

      index ->
        entries = List.update_at(state.entries, index, &%{&1 | status: status})
        %{state | entries: entries}
    end
  end

  defp append(state, entry), do: %{state | entries: state.entries ++ [entry]}
end
