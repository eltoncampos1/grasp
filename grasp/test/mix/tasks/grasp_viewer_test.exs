defmodule Mix.Tasks.Grasp.ViewerTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Grasp.Viewer

  @moduletag :tmp_dir

  test "the viewer keeps its review beside the project it reads", %{tmp_dir: tmp_dir} do
    project = Path.expand(tmp_dir)
    index = %Grasp.Index{project: %{"root" => project}}

    assert Viewer.home(index) == project
  end

  test "an index whose project is not on this machine falls back to the working directory",
       %{tmp_dir: tmp_dir} do
    index = %Grasp.Index{project: %{"root" => Path.join(tmp_dir, "not-checked-out")}}

    assert Viewer.home(index) == File.cwd!()
  end

  test "an index that names no project root falls back to the working directory" do
    assert Viewer.home(%Grasp.Index{project: %{}}) == File.cwd!()
  end
end
