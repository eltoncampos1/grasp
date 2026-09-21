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

    assert Enum.map(entries, & &1.type) == [:user, :assistant, :tool, :tool, :assistant, :done]
    assert %{type: :done, cost_usd: 0.01, ms: 4200} = List.last(entries)

    %{last_result: argv} = Grasp.Agent.get(name)
    assert argv =~ "--strict-mcp-config"
    assert argv =~ "/mcp"
    assert argv =~ ~s(session: "#{name}")
  end

  test "the view carries the epoch the run started at and drops it when it ends", %{name: name} do
    assert Grasp.Agent.get(name).started_at == nil

    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert %{running?: true, started_at: started_at} = Grasp.Agent.get(name)
    assert is_integer(started_at)
    assert abs(started_at - System.system_time(:millisecond)) < 5_000

    assert_receive {:agent, ^name, %{running?: false, started_at: nil}}, 2_000
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

  test "set_model/2 picks the model of the next run and survives a reset", %{name: name} do
    assert Grasp.Agent.get(name).model == nil
    assert {:error, :unknown_model} = Grasp.Agent.set_model(name, "gpt-99")
    :ok = Grasp.Agent.set_model(name, "haiku")
    assert_receive {:agent, ^name, %{model: "haiku"}}

    :ok = Grasp.Agent.send_prompt(name, "cheap question")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "--model haiku"

    :ok = Grasp.Agent.reset(name)
    assert_receive {:agent, ^name, %{last_result: nil, model: "haiku"}}

    :ok = Grasp.Agent.set_model(name, nil)
    assert_receive {:agent, ^name, %{model: nil}}
    :ok = Grasp.Agent.send_prompt(name, "back to default")
    assert_receive {:agent, ^name, %{running?: false, last_result: "" <> argv}}, 2_000
    refute argv =~ "--model"
  end

  test "set_mode/2 arms the next run with the editing tools and survives a reset", %{name: name} do
    assert Grasp.Agent.get(name).mode == "read"
    assert {:error, :unknown_mode} = Grasp.Agent.set_mode(name, "bogus")
    :ok = Grasp.Agent.set_mode(name, "edit")
    assert_receive {:agent, ^name, %{mode: "edit"}}

    :ok = Grasp.Agent.send_prompt(name, "address the comments")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    argv = Grasp.Agent.get(name).last_result
    assert argv =~ "Bash(mix:*)"
    assert argv =~ "You may edit files under the project root"

    :ok = Grasp.Agent.reset(name)
    assert_receive {:agent, ^name, %{last_result: nil, mode: "edit"}}
  end

  test "a read-mode run is given no tool that writes", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "show me greet")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000

    argv = Grasp.Agent.get(name).last_result
    assert argv =~ "--allowedTools mcp__grasp,Read,Grep,Glob "
    refute argv =~ "Bash"
  end

  test "a prompt sent while a run is live is queued and runs when the port is free", %{
    name: name
  } do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "two")
    assert %{running?: true, queue: ["two"]} = Grasp.Agent.get(name)

    assert_receive {:agent, ^name, %{running?: false, entries: entries, queue: []}}, 4_000
    texts = entries |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.text)
    assert texts == ["SLOW one", "two"]
  end

  test "the queue is emptied by a stop and nothing more is run", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "two")

    :ok = Grasp.Agent.stop(name)
    assert %{running?: false, queue: []} = Grasp.Agent.get(name)

    Process.sleep(200)
    assert %{running?: false, entries: entries} = Grasp.Agent.get(name)
    assert Enum.count(entries, &(&1.type == :user)) == 1
  end

  test "reset/1 empties the queue", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "two")

    :ok = Grasp.Agent.reset(name)
    assert %{entries: [], queue: []} = Grasp.Agent.get(name)

    Process.sleep(200)
    assert %{running?: false, entries: []} = Grasp.Agent.get(name)
  end

  test "dequeue/2 withdraws one queued prompt", %{name: name} do
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "two")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "three")
    assert %{queue: ["two", "three"]} = Grasp.Agent.get(name)

    :ok = Grasp.Agent.dequeue(name, 0)
    assert %{queue: ["three"]} = Grasp.Agent.get(name)

    assert_receive {:agent, ^name, %{running?: false, entries: entries, queue: []}}, 4_000
    texts = entries |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.text)
    assert texts == ["SLOW one", "three"]
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
