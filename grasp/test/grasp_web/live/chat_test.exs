defmodule GraspWeb.ChatTest do
  use GraspWeb.ConnCase, async: true

  @greeter "SampleApp.Greeter.greet/2"

  setup %{conn: conn} do
    name = "t-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "the panel toggles from the toolbar and starts hidden", %{view: view} do
    assert has_element?(view, "#chat[hidden]")
    view |> element("#toggle-chat") |> render_click()
    refute has_element?(view, "#chat[hidden]")
    assert has_element?(view, "#chat input#chat-prompt")
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, "#chat[hidden]")
  end

  test "sending a prompt streams the transcript into the panel", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    # Subscribed before the run starts: the fake CLI can finish before a later subscribe lands.
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert has_element?(view, ~s(#chat .msg[data-type="user"]), "show me greet")

    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    html = render(view)
    assert html =~ "Looking at the flow."

    assert has_element?(
             view,
             ~s(#chat .msg[data-type="tool"][data-status="done"]),
             "search_functions"
           )

    assert has_element?(view, ~s(#chat .msg[data-type="done"]), "2 turns")
    refute has_element?(view, "#chat button[disabled]", "Send")
  end

  test "an answer renders as Markdown whose function ids open cards", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000

    assert has_element?(view, ~s(#chat .msg[data-type="assistant"] strong), "greet")
    assert has_element?(view, ~s(#chat pre.fence[data-lang="elixir"]))
    assert has_element?(view, ~s(#chat pre.fence span.l-module), "SampleApp")

    # An id the fixture index holds is a button; one it does not stays as written.
    assert has_element?(view, ~s(#chat button.fn[phx-click="open_root"]), @greeter)
    assert has_element?(view, "#chat code", "Nope.Missing.fun/1")

    html = render(view)
    refute html =~ "script"
    refute html =~ "alert(1)"

    view |> element(~s(#chat button.fn[phx-value-id="#{@greeter}"])) |> render_click()
    assert has_element?(view, ~s(.card[data-function-id="#{@greeter}"]))
  end

  test "the model picker chooses the CLI model for the next run", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, ~s(#chat-model-select option[value=""][selected]))

    view |> form("#chat-model", %{"model" => "sonnet"}) |> render_change()
    assert has_element?(view, ~s(#chat-model-select option[value="sonnet"][selected]))

    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "--model sonnet"
  end

  test "the mode picker lets the next run edit files", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    assert has_element?(view, ~s(#chat-mode-select option[value="read"][selected]))

    view |> form("#chat-mode", %{"mode" => "edit"}) |> render_change()
    assert has_element?(view, ~s(#chat-mode-select option[value="edit"][selected]))
    assert Grasp.Agent.get(name).mode == "edit"

    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "address the comments"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert Grasp.Agent.get(name).last_result =~ "Bash(mix:*)"
  end

  test "a mode the agent does not know leaves the chat as it was", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    render_change(view, :chat_mode, %{"mode" => "sudo"})

    assert Grasp.Agent.get(name).mode == "read"
    assert has_element?(view, ~s(#chat-mode-select option[value="read"][selected]))
  end

  test "a blank prompt is ignored", %{view: view} do
    view |> element("#toggle-chat") |> render_click()
    view |> form("#chat-form", %{"prompt" => "   "}) |> render_submit()
    refute has_element?(view, ~s(#chat .msg[data-type="user"]))
  end

  test "a failed run shows the error and the log", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "FAIL please"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    assert has_element?(view, ~s(#chat .msg[data-type="error"]), "status 3")
    assert has_element?(view, "#chat .chat__debug", "something went wrong on stderr")
  end

  test "a live run disables Send, offers Stop, and New clears the transcript", %{
    view: view,
    name: name
  } do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()

    assert has_element?(view, "#chat button[disabled]", "Send")
    view |> element(~s(#chat button[phx-click="chat_stop"]), "Stop") |> render_click()
    refute has_element?(view, "#chat button[disabled]", "Send")

    view |> element(~s(#chat button[phx-click="chat_reset"]), "New") |> render_click()
    refute has_element?(view, ~s(#chat .msg[data-type="user"]))
  end
end
