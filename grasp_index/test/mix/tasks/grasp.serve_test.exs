defmodule Mix.Tasks.Grasp.ServeTest do
  # The runner and the Mix shell are global, so this module has the whole VM to itself.
  use ExUnit.Case, async: false

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    on_exit(fn ->
      Mix.shell(shell)
      Application.delete_env(:grasp_index, :viewer_runner)
    end)

    :ok
  end

  @tag :tmp_dir
  test "says to build an index first when there is none", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, ".grasp/index.json")

    assert_raise Mix.Error, ~r/run mix grasp\.index first/, fn ->
      Mix.Tasks.Grasp.Serve.run(["--index", missing])
    end
  end

  @tag :tmp_dir
  test "runs the viewer with the index and the forwarded options", %{tmp_dir: tmp_dir} do
    index = Path.join(tmp_dir, "index.json")
    File.write!(index, "{}")
    checkout = ready_checkout(tmp_dir)
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Application.put_env(:grasp_index, :viewer_runner, fn command, dir ->
      Agent.update(agent, &[{command, dir} | &1])
      0
    end)

    Mix.Tasks.Grasp.Serve.run([
      "--index",
      index,
      "--viewer",
      checkout,
      "--editor",
      "vscode"
    ])

    assert Agent.get(agent, &Enum.reverse/1) == [
             {["mix", "grasp.viewer", "--index", index, "--editor", "vscode"],
              Path.join(checkout, "grasp")}
           ]
  end

  defp ready_checkout(dir) do
    checkout = Path.join(dir, "viewer")
    project = Path.join(checkout, "grasp")
    File.mkdir_p!(Path.join(project, "deps"))
    File.mkdir_p!(Path.join(project, "priv/static/assets"))
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "priv/static/assets/app.js"), "")
    checkout
  end
end
