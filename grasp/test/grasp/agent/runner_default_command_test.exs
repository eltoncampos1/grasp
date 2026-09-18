defmodule Grasp.Agent.RunnerDefaultCommandTest do
  # Unsets the globally configured agent command and edits PATH, so it cannot share the run
  # with the tests that expect the fake CLI at its configured path.
  use ExUnit.Case, async: false

  # A host installs Grasp as a dependency and never evaluates its `config/config.exs`, so
  # every `:grasp` key is unset there. The fake CLI is put on PATH under the name the default
  # names, which is what a machine with Claude Code installed looks like.
  setup do
    configured = Application.fetch_env!(:grasp, :agent_command)
    path = System.get_env("PATH")

    dir =
      Path.join(System.tmp_dir!(), "grasp-default-command-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.ln_s!(configured, Path.join(dir, "claude"))
    Application.delete_env(:grasp, :agent_command)
    System.put_env("PATH", dir <> ":" <> path)

    on_exit(fn ->
      Application.put_env(:grasp, :agent_command, configured)
      System.put_env("PATH", path)
      File.rm_rf!(dir)
    end)

    name = "t-#{System.unique_integer([:positive])}"
    :ok = Grasp.Agent.ensure(name)
    %{name: name}
  end

  test "a run starts on the default command when nothing is configured", %{name: name} do
    :ok = Grasp.Agent.subscribe(name)

    assert :ok = Grasp.Agent.send_prompt(name, "show me greet")
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "show me greet"
  end
end
