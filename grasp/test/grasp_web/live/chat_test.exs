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
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
    log = view |> element("#chat-log") |> render()

    # The block that follows the deltas is the authoritative text, not a second copy of it.
    assert length(String.split(log, "Looking at the flow.")) == 2

    assert has_element?(view, ~s(#chat details.tools summary), "Used 2 tools")
    assert has_element?(view, ~s(#chat .tool[data-status="done"]), ~s(Searched "greet"))
    assert has_element?(view, ~s(#chat .tool[data-status="error"]), "Arranged 3 cards")
    assert has_element?(view, ~s(#chat .tool[data-status="error"] pre), "no such function")
    assert has_element?(view, ~s(#chat .msg[data-type="done"]), "$0.01 · 2 turns · 4.2 s")
    refute has_element?(view, "#chat .chat__status")
    refute has_element?(view, "#chat button[disabled]", "Send")
  end

  test "a live run shows that the agent is working", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "SLOW one"}) |> render_submit()

    assert has_element?(view, ~s(#chat .msg[data-type="thinking"])) or
             has_element?(view, ~s(#chat details.tools[open]))

    assert has_element?(view, "#chat .chat__status", "Working")
    assert has_element?(view, "#chat .chat__status span[data-elapsed-from]")

    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
    refute has_element?(view, ~s(#chat .msg[data-type="thinking"]))
    refute has_element?(view, "#chat .chat__status")
  end

  test "an answer renders as Markdown whose function ids open cards", %{view: view, name: name} do
    view |> element("#toggle-chat") |> render_click()
    :ok = Grasp.Agent.subscribe(name)
    view |> form("#chat-form", %{"prompt" => "show me greet"}) |> render_submit()
    assert_receive {:agent, ^name, %{running?: false}}, 2_000
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)

    assert has_element?(view, ~s(#chat .msg[data-type="assistant"] strong), "greet")
    assert has_element?(view, ~s(#chat pre.fence[data-lang="elixir"]))
    assert has_element?(view, ~s(#chat pre.fence span.l-module), "SampleApp")

    # An id the fixture index holds is a button; one it does not stays as written. The button
    # carries the id and no event: the panel's hook, not the answer's markup, names the event.
    assert has_element?(view, ~s(#chat button.fn[data-fn="#{@greeter}"]), @greeter)
    assert has_element?(view, "#chat code", "Nope.Missing.fun/1")
    refute has_element?(view, "#chat-log [phx-click]")

    log = view |> element("#chat-log") |> render()
    refute log =~ "script"
    refute log =~ "alert(1)"

    # What the hook pushes when that button is clicked.
    view |> element("#chat") |> render_hook("open_root", %{"id" => @greeter})
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
    eventually(view, fn -> not has_element?(view, ~s(#chat button[phx-click="chat_stop"])) end)
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

  # A broadcast the test received is not a broadcast the LiveView has handled: PubSub
  # dispatches by registry partition, so the subscriber that joined second can be notified
  # first, and a render asked for in that window shows the run as it was. Every assertion
  # that reads the panel the moment a run ends waits here until the panel itself says the
  # run is over — the Stop button is drawn only while one is live.
  defp eventually(view, predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("the panel never reached the state the test waited for")

      true ->
        Process.sleep(10)
        render(view)
        eventually(view, predicate, attempts - 1)
    end
  end
end
