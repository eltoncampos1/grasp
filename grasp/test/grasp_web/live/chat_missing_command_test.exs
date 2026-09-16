defmodule GraspWeb.ChatMissingCommandTest do
  # Swaps the globally configured agent command, so it cannot share the run with the tests
  # that expect the fake CLI.
  use GraspWeb.ConnCase, async: false

  setup %{conn: conn} do
    previous = Application.get_env(:grasp, :agent_command)
    Application.put_env(:grasp, :agent_command, "/definitely/not/here")
    on_exit(fn -> Application.put_env(:grasp, :agent_command, previous) end)

    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view}
  end

  test "a missing claude command is named in the panel, and reopening it clears the notice", %{
    view: view
  } do
    view |> element("#toggle-chat") |> render_click()
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()

    assert has_element?(view, ~s(#chat .msg[data-type="error"]), "GRASP_AGENT_COMMAND")
    refute has_element?(view, ~s(#chat .msg[data-type="user"]))

    view |> element("#toggle-chat") |> render_click()
    view |> element("#toggle-chat") |> render_click()

    refute has_element?(view, ~s(#chat .msg[data-type="error"]))
  end
end
