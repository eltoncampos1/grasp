defmodule Grasp.Agent.Stream do
  @moduledoc """
  Folds the Claude Code CLI's `--output-format stream-json` output into a transcript.

  The CLI writes one JSON object per line: a `system`/`init` announcing the CLI session id
  and the MCP servers it managed to reach, `assistant` and `user` messages carrying content
  blocks, `stream_event` lines carrying the model's output as it is produced, and a final
  `result`. This module turns that sequence into the flat list of entries the viewer
  renders, oldest first, and is pure: the runner owns the port, this owns the meaning of
  what comes out of it.

  Text arrives twice. A `stream_event` carrying a `text_delta` grows a partial assistant
  entry, so the panel reads the answer as it is written; the `assistant` block that follows
  carries the whole of that text, so it replaces the partial entry rather than being
  appended to it. Anything else inside a `stream_event` — the tool arguments being
  assembled, the message envelope — is already reported by the block events, so it is
  ignored.

  Tool calls are two events apart — an `assistant` block starts one, a later `user` block
  reports it — so a tool entry is appended `:running` and closed when its result arrives.
  The result names the call it answers, and the entry records that name, because calls the
  model made together come back in whatever order they finished: closing by position would
  hang one call's failure and duration on another's row. A result naming nothing the
  transcript knows falls back to the oldest running entry, which is the order a CLI that
  does not name its results reports them in. Each
  entry records the clock reading it started at, and closing it subtracts that from the
  reading the closing line came in on, which is why the clock is an argument: a caller
  folding a canned run can pin both readings and get a duration it chose.

  A line that is not JSON goes to `log` rather than the transcript: with the port merging
  stderr into stdout, that is where a crash report or a CLI warning shows up, and dropping
  it would leave a failed run with nothing to explain it.
  """

  @type entry ::
          %{type: :user, text: String.t()}
          | %{type: :assistant, text: String.t(), partial: boolean()}
          | %{
              type: :tool,
              id: String.t() | nil,
              name: String.t(),
              summary: String.t(),
              status: :running | :done | :error,
              started_at: integer(),
              ms: non_neg_integer() | nil,
              detail: String.t() | nil
            }
          | %{type: :error, text: String.t()}
          | %{
              type: :done,
              cost_usd: float() | nil,
              turns: integer() | nil,
              ms: integer() | nil
            }

  @type t :: %{
          entries: [entry()],
          claude_session_id: String.t() | nil,
          log: [String.t()],
          done?: boolean(),
          result_text: String.t() | nil
        }

  @summary_keys ~w(query id to function_id file_path pattern)
  @detail_limit 2_000

  @doc "An empty transcript."
  @spec new() :: t()
  def new,
    do: %{entries: [], claude_session_id: nil, log: [], done?: false, result_text: nil}

  @doc """
  Folds one line of CLI output into `state`.

  `now` is the clock reading the line arrived on, in milliseconds, and is what a tool
  call's duration is measured against.

  A blank line is ignored, a line that does not decode as a JSON object is logged, and an
  event of an unknown type (or a `rate_limit_event`) leaves the state untouched.
  """
  @spec apply(t(), String.t()) :: t()
  @spec apply(t(), String.t(), integer()) :: t()
  def apply(state, line, now \\ System.monotonic_time(:millisecond)) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = event} -> event(state, event["type"], event, now)
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

  defp event(state, "system", %{"subtype" => "init"} = event, _now) do
    state
    |> Map.put(:claude_session_id, event["session_id"] || state.claude_session_id)
    |> check_mcp(event["mcp_servers"])
  end

  defp event(state, "assistant", event, now) do
    event
    |> content()
    |> Enum.reduce(state, &block(&1, &2, now))
  end

  # A `user` event reports the tool calls the CLI ran; anything else in it echoes what was
  # sent to the model, and putting that in the transcript would read as the agent speaking.
  defp event(state, "user", event, now) do
    event
    |> content()
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result"))
    |> Enum.reduce(state, &block(&1, &2, now))
  end

  defp event(state, "stream_event", %{"event" => inner}, _now) when is_map(inner) do
    case inner do
      %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}
      when is_binary(text) ->
        delta(state, text)

      _other ->
        state
    end
  end

  defp event(state, "result", event, _now) do
    state = %{state | done?: true, result_text: event["result"]}

    state =
      if event["is_error"] do
        error(state, event["result"] || event["subtype"])
      else
        state
      end

    append(state, %{
      type: :done,
      cost_usd: event["total_cost_usd"],
      turns: event["num_turns"],
      ms: event["duration_ms"]
    })
  end

  defp event(state, _type, _event, _now), do: state

  defp content(%{"message" => %{"content" => blocks}}) when is_list(blocks), do: blocks
  defp content(_event), do: []

  defp block(%{"type" => "text", "text" => text}, state, _now), do: assistant(state, text)

  defp block(%{"type" => "tool_use"} = block, state, now) do
    input = block["input"] || %{}

    append(state, %{
      type: :tool,
      id: block["id"],
      name: String.replace_prefix(block["name"] || "", "mcp__grasp__", ""),
      summary: summary(input),
      status: :running,
      started_at: now,
      ms: nil,
      detail: nil
    })
  end

  defp block(%{"type" => "tool_result"} = block, state, now) do
    if block["is_error"] do
      close(state, block["tool_use_id"], :error, now, detail(block["content"]))
    else
      close(state, block["tool_use_id"], :done, now, nil)
    end
  end

  defp block(_block, state, _now), do: state

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

  # What a failing tool said. The CLI writes a result's content either as one string or as
  # the content blocks the tool answered with; anything longer than a paragraph or two is
  # a stack trace the panel has no room for.
  defp detail(content) when is_binary(content), do: trim(content)

  defp detail(content) when is_list(content) do
    content
    |> Enum.find_value(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _block -> nil
    end)
    |> case do
      nil -> nil
      text -> trim(text)
    end
  end

  defp detail(_content), do: nil

  defp trim(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @detail_limit)
    end
  end

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

  # The whole of a block of text, which settles whatever was streamed of it.
  defp assistant(state, text) do
    case List.last(state.entries) do
      %{type: :assistant, partial: true} ->
        replace_last(state, %{type: :assistant, text: text, partial: false})

      %{type: :assistant, text: previous, partial: false} ->
        replace_last(state, %{type: :assistant, text: previous <> text, partial: false})

      _other ->
        append(state, %{type: :assistant, text: text, partial: false})
    end
  end

  # One more piece of a block of text that is still being written.
  defp delta(state, text) do
    case List.last(state.entries) do
      %{type: :assistant, text: previous, partial: true} ->
        replace_last(state, %{type: :assistant, text: previous <> text, partial: true})

      _other ->
        append(state, %{type: :assistant, text: text, partial: true})
    end
  end

  defp close(state, id, status, now, detail) do
    case answered(state.entries, id) do
      nil ->
        state

      index ->
        entries =
          List.update_at(
            state.entries,
            index,
            &%{&1 | status: status, ms: max(now - &1.started_at, 0), detail: detail}
          )

        %{state | entries: entries}
    end
  end

  # The entry a result answers: the running call it names, or the oldest call still running
  # when it names one the transcript never saw.
  defp answered(entries, id) do
    by_id =
      is_binary(id) and
        Enum.find_index(entries, &(&1.type == :tool and &1.status == :running and &1.id == id))

    case by_id do
      index when is_integer(index) ->
        index

      _unnamed ->
        Enum.find_index(entries, &(&1.type == :tool and &1.status == :running))
    end
  end

  defp replace_last(state, entry),
    do: %{state | entries: List.replace_at(state.entries, -1, entry)}

  defp append(state, entry), do: %{state | entries: state.entries ++ [entry]}
end
