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
    %{name: name}
  end

  test "a command that resolves to nothing is reported rather than spawned", %{name: name} do
    assert {:error, :no_command} = Grasp.Agent.send_prompt(name, "show me greet")
    assert %{entries: [], running?: false} = Grasp.Agent.get(name)
  end
end
