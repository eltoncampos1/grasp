defmodule Grasp.Agent.StreamTest do
  use ExUnit.Case, async: true

  alias Grasp.Agent.Stream

  @init ~s({"type":"system","subtype":"init","session_id":"fake-1","mcp_servers":[{"name":"grasp","status":"connected"}]})
  @text ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the flow."}]}})
  @tool_use ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__grasp__search_functions","input":{"query":"greet","limit":5}}]}})
  @tool_result ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"[]"}]}})
  @more_text ~s({"type":"assistant","message":{"content":[{"type":"text","text":" Done."}]}})
  @result ~s({"type":"result","subtype":"success","is_error":false,"num_turns":2,"total_cost_usd":0.01,"session_id":"fake-1","result":"all done"})

  defp fold(lines), do: Enum.reduce(lines, Stream.new(), &Stream.apply(&2, &1))

  test "a whole run folds into a transcript" do
    state = fold([@init, @text, @tool_use, @tool_result, @more_text, @result])

    assert state.claude_session_id == "fake-1"
    assert state.done?
    assert state.result_text == "all done"
    assert state.log == []

    assert [assistant, tool, more, done] = state.entries
    assert assistant == %{type: :assistant, text: "Looking at the flow."}
    assert tool == %{type: :tool, name: "search_functions", summary: "greet", status: :done}
    assert more == %{type: :assistant, text: " Done."}
    assert done == %{type: :done, cost_usd: 0.01, turns: 2}
  end

  test "consecutive assistant text blocks merge into one entry" do
    state =
      fold([
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"one"},{"type":"text","text":" two"}]}}),
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":" three"}]}})
      ])

    assert state.entries == [%{type: :assistant, text: "one two three"}]
  end

  test "a text block in a user event is not the agent speaking" do
    echo = ~s({"type":"user","message":{"content":[{"type":"text","text":"show me greet"}]}})
    state = fold([echo])
    assert state.entries == []
  end

  test "a non-JSON line goes to the log" do
    state = fold(["something went wrong on stderr", @init])

    assert state.log == ["something went wrong on stderr"]
    assert state.entries == []
  end

  test "an init without a connected grasp server reports the status" do
    failed =
      ~s({"type":"system","subtype":"init","session_id":"fake-fail","mcp_servers":[{"name":"grasp","status":"failed"}]})

    assert [%{type: :error, text: text}] = fold([failed]).entries
    assert text =~ "failed"

    missing = ~s({"type":"system","subtype":"init","session_id":"x","mcp_servers":[]})
    assert [%{type: :error, text: text}] = fold([missing]).entries
    assert text =~ "missing"
  end

  test "a failed tool result marks the tool entry as an error" do
    failed =
      ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"boom","is_error":true}]}})

    assert [%{type: :tool, status: :error}] = fold([@tool_use, failed]).entries
  end

  test "the oldest running tool is the one a result closes" do
    second =
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"lib/a.ex"}}]}})

    state = fold([@tool_use, second, @tool_result])

    assert [%{name: "search_functions", status: :done}, %{name: "Read", status: :running}] =
             state.entries
  end

  test "an errored result appends an error entry before the done entry" do
    failed =
      ~s({"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":9,"total_cost_usd":0.5,"result":"ran out of turns"})

    assert [%{type: :error, text: "ran out of turns"}, %{type: :done, turns: 9}] =
             fold([failed]).entries
  end

  test "a new prompt joins the transcript and clears the previous run's conclusion" do
    state = Stream.prompt(fold([@init, @result]), "and then?")

    refute state.done?
    assert state.result_text == nil
    assert List.last(state.entries) == %{type: :user, text: "and then?"}
    assert state.claude_session_id == "fake-1"
  end

  test "a card layout summarises as a card count" do
    cards =
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__grasp__set_cards","input":{"cards":[1,2,3]}}]}})

    assert [%{type: :tool, name: "set_cards", summary: "3 cards"}] = fold([cards]).entries
  end

  test "an input with nothing summarisable summarises as an empty string" do
    bare =
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Glob","input":{}}]}})

    assert [%{type: :tool, name: "Glob", summary: ""}] = fold([bare]).entries
  end

  test "rate limit events, unknown types and blank lines are ignored" do
    state = fold([~s({"type":"rate_limit_event","x":1}), ~s({"type":"nonesuch"}), "", "   "])

    assert state == Stream.new()
  end
end
