defmodule Grasp.Agent.RunnerTest do
  use ExUnit.Case, async: true

  setup do
    name = "t-#{System.unique_integer([:positive])}"
    :ok = Grasp.Agent.ensure(name)
    :ok = Grasp.Agent.subscribe(name)
    %{name: name}
  end

  test "a prompt runs the command and streams the transcript", %{name: name} do
    assert :ok = Grasp.Agent.send_prompt(name, "show me greet")

    assert_receive {:agent, ^name,
                    %{running?: true, entries: [%{type: :user, text: "show me greet"}]}}

    assert_receive {:agent, ^name,
                    %{running?: false, entries: entries, claude_session_id: "fake-1"}},
                   2_000

    assert Enum.map(entries, & &1.type) == [:user, :assistant, :tool, :assistant, :done]
    assert %{type: :done, cost_usd: 0.01} = List.last(entries)

    %{last_result: argv} = Grasp.Agent.get(name)
    assert argv =~ "--strict-mcp-config"
    assert argv =~ "/mcp"
    assert argv =~ ~s(session: "#{name}")
  end

  test "a second prompt resumes the CLI session the first one opened", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "first")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    refute Grasp.Agent.get(name).last_result =~ "--resume"

    :ok = Grasp.Agent.send_prompt(name, "second")
    assert_receive {:agent, ^name, %{running?: false, entries: entries}}, 2_000

    assert Grasp.Agent.get(name).last_result =~ "--resume fake-1"
    assert Enum.count(entries, &(&1.type == :user)) == 2
  end

  test "a prompt sent while a run is live is refused", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert {:error, :running} = Grasp.Agent.send_prompt(name, "two")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
  end

  test "stop/1 ends a live run", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    :ok = Grasp.Agent.stop(name)

    assert_receive {:agent, ^name, %{running?: false, entries: entries}}, 1_000
    assert %{type: :error, text: "stopped"} = List.last(entries)
  end

  test "a non-zero exit is reported with the command's output", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "FAIL please")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000

    %{entries: entries, log: log} = Grasp.Agent.get(name)
    assert Enum.any?(entries, &(&1.type == :error and &1.text =~ "status 3"))
    assert Enum.any?(entries, &(&1.type == :error and &1.text =~ "failed"))
    assert Enum.any?(log, &(&1 =~ "something went wrong on stderr"))
  end

  test "reset/1 empties the transcript and starts a fresh CLI session", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "first")
    assert_receive {:agent, ^name, %{running?: false, claude_session_id: "fake-1"}}, 2_000

    assert :ok = Grasp.Agent.reset(name)

    assert %{entries: [], log: [], claude_session_id: nil, last_result: nil, running?: false} =
             Grasp.Agent.get(name)

    :ok = Grasp.Agent.send_prompt(name, "second")
    # The reset broadcast is also `running?: false`; only a finished run has a session id.
    assert_receive {:agent, ^name, %{running?: false, claude_session_id: "fake-1"}}, 2_000
    refute Grasp.Agent.get(name).last_result =~ "--resume"
  end

  test "reset/1 stops a live run", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert :ok = Grasp.Agent.reset(name)

    assert %{entries: [], running?: false} = Grasp.Agent.get(name)
  end
end
