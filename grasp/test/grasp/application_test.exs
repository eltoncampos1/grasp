defmodule Grasp.ApplicationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  test "the running tree serves its own endpoint, because the test environment is standalone" do
    assert Application.get_env(:grasp, :standalone) == true

    started = Grasp.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    assert GraspWeb.Endpoint in started
    assert Grasp.IndexStore in started
    assert Grasp.MCP.Server in started
  end

  test "mounted in a host application Grasp starts its core and no endpoint" do
    children = Grasp.Application.children(true, false)

    assert {Grasp.IndexStore, []} in children
    assert {Grasp.Comments, []} in children
    refute GraspWeb.Endpoint in children
  end

  test "without Mix there is nothing to start" do
    log = capture_log(fn -> assert Grasp.Application.children(false, true) == [] end)

    assert log =~ "Mix is not running"
  end
end
