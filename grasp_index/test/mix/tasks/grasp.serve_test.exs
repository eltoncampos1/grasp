defmodule Mix.Tasks.Grasp.ServeTest do
  # The runner and the Mix shell are global, so this module has the whole VM to itself.
  use ExUnit.Case, async: false

  setup do
    shell = Mix.shell()
    runner = Application.fetch_env(:grasp_index, :viewer_runner)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(shell)

      case runner do
        {:ok, runner} -> Application.put_env(:grasp_index, :viewer_runner, runner)
        :error -> Application.delete_env(:grasp_index, :viewer_runner)
      end
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
    recorded = record_runner()

    Mix.Tasks.Grasp.Serve.run(["--index", index, "--viewer", checkout, "--editor", "vscode"])

    assert recorded.() == [
             {["mix", "grasp.viewer", "--index", index, "--editor", "vscode"],
              Path.join(checkout, "grasp")}
           ]
  end

  @tag :tmp_dir
  test "reads the index the indexer writes under the current directory", %{tmp_dir: tmp_dir} do
    index = Path.join(tmp_dir, ".grasp/index.json")
    File.mkdir_p!(Path.dirname(index))
    File.write!(index, "{}")
    checkout = ready_checkout(tmp_dir)
    recorded = record_runner()

    File.cd!(tmp_dir, fn -> Mix.Tasks.Grasp.Serve.run(["--viewer", checkout]) end)

    assert [{["mix", "grasp.viewer", "--index", served], _dir}] = recorded.()
    assert served == Path.expand(index)
  end

  @tag :tmp_dir
  test "says what it is doing before each step", %{tmp_dir: tmp_dir} do
    index = Path.join(tmp_dir, "index.json")
    File.write!(index, "{}")
    checkout = Path.join(tmp_dir, "viewer")
    project = Path.join(checkout, "grasp")

    Application.put_env(:grasp_index, :viewer_runner, fn
      ["git", "clone" | _rest], _dir ->
        File.mkdir_p!(project)
        File.write!(Path.join(project, "mix.exs"), "")
        0

      _argv, _dir ->
        0
    end)

    Mix.Tasks.Grasp.Serve.run(["--index", index, "--viewer", checkout])

    cloning = "Cloning the Grasp viewer into #{checkout}"
    starting = "Starting the viewer from #{project}"

    assert_received {:mix_shell, :info, [^cloning]}
    assert_received {:mix_shell, :info, ["Fetching the viewer's dependencies…"]}
    assert_received {:mix_shell, :info, ["Building the viewer's assets…"]}
    assert_received {:mix_shell, :info, [^starting]}
  end

  defp record_runner do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    Application.put_env(:grasp_index, :viewer_runner, fn command, dir ->
      Agent.update(agent, &[{command, dir} | &1])
      0
    end)

    fn -> Agent.get(agent, &Enum.reverse/1) end
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
