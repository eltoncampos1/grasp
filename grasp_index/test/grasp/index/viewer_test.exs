defmodule Grasp.Index.ViewerTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Viewer

  @argv ["--index", "/tmp/project/.grasp/index.json"]
  @repo "https://example.com/grasp.git"

  describe "checkout/1" do
    test "serves the current directory when the current project is the viewer" do
      assert Viewer.checkout(
               viewer: nil,
               env: %{"GRASP_VIEWER" => "/env"},
               cwd: "/repo/grasp",
               cwd_app: :grasp
             ) == "/repo/grasp"
    end

    test "takes the given path even inside the viewer" do
      assert Viewer.checkout(
               viewer: "/elsewhere",
               env: %{},
               cwd: "/repo/grasp",
               cwd_app: :grasp
             ) == "/elsewhere"
    end

    test "takes the given path over the environment" do
      assert Viewer.checkout(
               viewer: "/given",
               env: %{"GRASP_VIEWER" => "/env"},
               cwd: "/project",
               cwd_app: :acme
             ) == "/given"
    end

    test "takes the environment over the default" do
      assert Viewer.checkout(
               viewer: nil,
               env: %{"GRASP_VIEWER" => "/env"},
               cwd: "/project",
               cwd_app: :acme
             ) == "/env"
    end

    test "reads a relative path from the directory it was given in" do
      assert Viewer.checkout(
               viewer: "../grasp",
               env: %{},
               cwd: "/work/sample_app",
               cwd_app: :sample_app
             ) == "/work/grasp"

      assert Viewer.checkout(
               viewer: nil,
               env: %{"GRASP_VIEWER" => "checkouts/grasp"},
               cwd: "/work/sample_app",
               cwd_app: :sample_app
             ) == "/work/sample_app/checkouts/grasp"
    end

    test "falls back to a directory under the home directory" do
      checkout = Viewer.checkout(viewer: nil, env: %{}, cwd: "/project", cwd_app: :acme)

      assert String.ends_with?(checkout, ".grasp/viewer")
      assert checkout == Path.expand(checkout)
    end
  end

  describe "project/1" do
    @tag :tmp_dir
    test "finds the viewer beside the indexer in a checkout of the repository", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, "grasp"))
      File.write!(Path.join(tmp_dir, "grasp/mix.exs"), "")

      assert Viewer.project(tmp_dir) == Path.join(tmp_dir, "grasp")
    end

    @tag :tmp_dir
    test "takes a directory that is itself the project", %{tmp_dir: tmp_dir} do
      assert Viewer.project(tmp_dir) == tmp_dir
    end
  end

  describe "steps/3" do
    @tag :tmp_dir
    test "clones, prepares and serves a checkout that is not there yet", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "viewer")
      project = Path.join(missing, "grasp")

      assert Viewer.steps(missing, @repo, @argv) == [
               {:clone, @repo, missing},
               {:deps, project},
               {:assets, project},
               {:serve, project, @argv}
             ]
    end

    @tag :tmp_dir
    test "only serves a checkout with its dependencies and assets in place", %{tmp_dir: tmp_dir} do
      project = ready_checkout(tmp_dir)

      assert Viewer.steps(tmp_dir, @repo, @argv) == [{:serve, project, @argv}]
    end

    @tag :tmp_dir
    test "fetches dependencies when the project has none", %{tmp_dir: tmp_dir} do
      project = ready_checkout(tmp_dir)
      File.rm_rf!(Path.join(project, "deps"))

      assert Viewer.steps(tmp_dir, @repo, @argv) == [{:deps, project}, {:serve, project, @argv}]
    end

    @tag :tmp_dir
    test "builds assets when the project has none built", %{tmp_dir: tmp_dir} do
      project = ready_checkout(tmp_dir)
      File.rm!(Path.join(project, "priv/static/assets/app.js"))

      assert Viewer.steps(tmp_dir, @repo, @argv) == [{:assets, project}, {:serve, project, @argv}]
    end
  end

  describe "run/3" do
    @tag :tmp_dir
    test "runs each command in the directory it belongs to", %{tmp_dir: tmp_dir} do
      checkout = Path.join(tmp_dir, "viewer")
      project = Path.join(checkout, "grasp")
      {recorder, recorded} = recording_runner(clones(project))

      assert Viewer.run(Viewer.steps(checkout, @repo, @argv), recorder) == :ok

      assert recorded.() == [
               {["git", "clone", "--progress", "--", @repo, checkout], tmp_dir},
               {["mix", "deps.get"], project},
               {["mix", "assets.build"], project},
               {["mix", "grasp.viewer" | @argv], project}
             ]
    end

    @tag :tmp_dir
    test "creates no directory of its own on the way to the checkout", %{tmp_dir: tmp_dir} do
      checkout = Path.join(tmp_dir, "below/viewer")
      {recorder, recorded} = recording_runner(0)

      assert Viewer.run(Viewer.steps(checkout, @repo, @argv), recorder) ==
               {:error,
                "#{checkout} is not a Grasp checkout (no mix.exs); remove it to clone afresh, or point --viewer at one"}

      refute File.exists?(Path.join(tmp_dir, "below"))
      assert recorded.() == [{["git", "clone", "--progress", "--", @repo, checkout], tmp_dir}]
    end

    @tag :tmp_dir
    test "takes the project from what the clone produced", %{tmp_dir: tmp_dir} do
      checkout = Path.join(tmp_dir, "viewer")
      {recorder, recorded} = recording_runner(clones(checkout))

      assert Viewer.run(Viewer.steps(checkout, @repo, @argv), recorder) == :ok

      assert recorded.() == [
               {["git", "clone", "--progress", "--", @repo, checkout], tmp_dir},
               {["mix", "deps.get"], checkout},
               {["mix", "assets.build"], checkout},
               {["mix", "grasp.viewer" | @argv], checkout}
             ]
    end

    @tag :tmp_dir
    test "refuses a checkout with no Mix project in it", %{tmp_dir: tmp_dir} do
      {recorder, recorded} = recording_runner(0)

      assert Viewer.run(Viewer.steps(tmp_dir, @repo, @argv), recorder) ==
               {:error,
                "#{tmp_dir} is not a Grasp checkout (no mix.exs); remove it to clone afresh, or point --viewer at one"}

      assert recorded.() == []
    end

    @tag :tmp_dir
    test "stops at the command that failed", %{tmp_dir: tmp_dir} do
      project = ready_checkout(tmp_dir)
      File.rm_rf!(Path.join(project, "deps"))
      {recorder, recorded} = recording_runner(fn ["mix", "deps.get"], _dir -> 1 end)

      assert Viewer.run(Viewer.steps(tmp_dir, @repo, @argv), recorder) ==
               {:error, "mix deps.get failed with status 1"}

      assert recorded.() == [{["mix", "deps.get"], project}]
    end

    @tag :tmp_dir
    test "announces each step as it starts", %{tmp_dir: tmp_dir} do
      checkout = Path.join(tmp_dir, "viewer")
      project = Path.join(checkout, "grasp")
      {recorder, _recorded} = recording_runner(clones(project))
      {:ok, announced} = Agent.start_link(fn -> [] end)

      assert Viewer.run(Viewer.steps(checkout, @repo, @argv), recorder, fn step ->
               Agent.update(announced, &[step | &1])
             end) == :ok

      assert Agent.get(announced, &Enum.reverse/1) == [
               {:clone, @repo, checkout},
               {:deps, project},
               {:assets, project},
               {:serve, project, @argv}
             ]
    end
  end

  defp ready_checkout(dir) do
    project = Path.join(dir, "grasp")
    File.mkdir_p!(Path.join(project, "deps"))
    File.mkdir_p!(Path.join(project, "priv/static/assets"))
    File.write!(Path.join(project, "mix.exs"), "")
    File.write!(Path.join(project, "priv/static/assets/app.js"), "")
    project
  end

  # A runner standing in for a clone that left a Mix project at `project`.
  defp clones(project) do
    fn
      ["git", "clone" | _rest], _dir ->
        File.mkdir_p!(project)
        File.write!(Path.join(project, "mix.exs"), "")
        0

      _argv, _dir ->
        0
    end
  end

  defp recording_runner(status) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    runner = fn command, dir ->
      Agent.update(agent, &[{command, dir} | &1])
      if is_function(status), do: status.(command, dir), else: status
    end

    {runner, fn -> Agent.get(agent, &Enum.reverse/1) end}
  end
end
