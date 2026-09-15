defmodule GraspWeb.SidebarTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Index

  test "a kind the project has no entry points for is not rendered as a group" do
    html = render_sidebar(without: ["genserver", "plug"])

    refute html =~ ~s|data-kind="genservers"|
    refute html =~ ~s|data-kind="plugs"|

    assert html =~ ~s|data-kind="routes"|
    assert html =~ ~s|data-kind="modules"|
    assert html =~ ~s|data-kind="otp"|
  end

  test "an index with no entry points at all still offers the module list" do
    html = render_sidebar(without: ~w(route live_route oban_worker live_view live_component
             genserver supervisor application plug))

    assert html =~ ~s|data-kind="modules"|
    refute html =~ ~s|class="entry"|
  end

  # The fixture is the only index with entry points of every kind, so a kind is removed
  # from its document rather than a second fixture being kept in step with it.
  defp render_sidebar(without: kinds) do
    document =
      "test/fixtures/index.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("entry_points", fn entries ->
        Enum.reject(entries, &(&1["kind"] in kinds))
      end)

    {:ok, index} = Index.from_document(document)

    render_component(&GraspWeb.Sidebar.entry_groups/1,
      index: index,
      expanded: MapSet.new(["routes"]),
      expanded_module: nil
    )
  end
end
