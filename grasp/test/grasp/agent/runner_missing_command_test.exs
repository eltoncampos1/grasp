defmodule Grasp.Agent.RunnerMissingCommandTest do
  # Swaps the globally configured agent command, so it cannot share the run with the
  # tests that expect the fake CLI.
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:grasp, :agent_command)
    Application.put_env(:grasp, :agent_command, "/definitely/not/here")
    on_exit(fn -> Application.put_env(:grasp, :agent_command, previous) end)

    name = "t-#{System.unique_integer([:positive])}"
    :ok = Grasp.Agent.ensure(name)
    %{name: name, fake_cli: previous}
  end

  test "a command that resolves to nothing is reported rather than spawned", %{name: name} do
    assert {:error, :no_command} = Grasp.Agent.send_prompt(name, "show me greet")
    assert %{entries: [], running?: false} = Grasp.Agent.get(name)
  end

  test "a command that exists but is not executable is reported too", %{name: name} do
    path =
      Path.join(System.tmp_dir!(), "grasp-not-executable-#{System.unique_integer([:positive])}")

    File.write!(path, "#!/bin/sh\necho hello\n")
    File.chmod!(path, 0o644)
    Application.put_env(:grasp, :agent_command, path)
    on_exit(fn -> File.rm_rf!(path) end)

    assert {:error, :no_command} = Grasp.Agent.send_prompt(name, "show me greet")
    assert Process.alive?(GenServer.whereis(Grasp.Agent.Runner.via(name)))
    assert %{entries: [], running?: false} = Grasp.Agent.get(name)
  end

  test "a command that goes missing mid-run drops the queue rather than stranding it", %{
    name: name,
    fake_cli: fake_cli
  } do
    Application.put_env(:grasp, :agent_command, fake_cli)
    :ok = Grasp.Agent.subscribe(name)
    :ok = Grasp.Agent.send_prompt(name, "SLOW one")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "two")
    assert {:ok, :queued} = Grasp.Agent.send_prompt(name, "three")

    Application.put_env(:grasp, :agent_command, "/definitely/not/here")

    assert_receive {:agent, ^name, %{running?: false, queue: [], entries: entries}}, 4_000
    assert %{type: :error, text: text} = List.last(entries)
    assert text =~ "2 queued prompts"

    # Nothing is left to jump the prompt typed after it.
    Application.put_env(:grasp, :agent_command, fake_cli)
    :ok = Grasp.Agent.send_prompt(name, "typed later")
    assert_receive {:agent, ^name, %{running?: false, queue: []}}, 4_000

    texts =
      Grasp.Agent.get(name).entries |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.text)

    assert texts == ["SLOW one", "typed later"]
  end
end
