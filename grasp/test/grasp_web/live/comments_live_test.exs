defmodule GraspWeb.CommentsLiveTest do
  use GraspWeb.ConnCase, async: true

  alias Grasp.Comments
  alias Grasp.Session

  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"

  setup %{conn: conn} do
    name = "c-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/s/#{name}")
    %{view: view, name: name}
  end

  test "a line's gutter opens a composer, and the comment lands under that line", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("the default argument hides an arity")

    view |> element("#card-1 .line[data-line='6'] .ln") |> render_click()

    assert has_element?(view, "#card-1 form.composer input[name='line'][value='6']")
    assert has_element?(view, "#card-1 form.composer input[name='side'][value='new']")

    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    refute has_element?(view, "#card-1 form.composer")
    assert has_element?(view, "#card-1 .thread .comment[data-author='human']")
    assert has_element?(view, "#card-1 .thread .comment__author", "you")

    html = render(view)
    assert before?(html, ~s(data-line="6"), body)
    assert before?(html, body, ~s(data-line="7"))
  end

  test "a thread is replied to, resolved, expanded and taken apart again", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("this clause never runs")
    reply = unique("it does when loud? is true")

    view |> element("#card-1 .line[data-line='8'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    id = thread_id(body)

    view |> element("#thread-#{id} .thread__actions button", "reply") |> render_click()
    assert has_element?(view, "#thread-#{id} form.composer textarea[placeholder='Reply…']")

    view |> form("#thread-#{id} form.composer", %{"body" => reply}) |> render_submit()

    assert has_element?(view, "#thread-#{id} .comment__body", body)
    assert has_element?(view, "#thread-#{id} .comment__body", reply)

    view |> element("#thread-#{id} .thread__actions button", "resolve") |> render_click()

    assert has_element?(view, "#thread-#{id}[data-resolved='true'] .thread__toggle")
    assert has_element?(view, "#thread-#{id} .thread__toggle", "Resolved · 2 comments")
    refute has_element?(view, "#thread-#{id} .comment__body")

    view |> element("#thread-#{id} .thread__toggle") |> render_click()

    assert has_element?(view, "#thread-#{id} .comment__body", reply)
    assert has_element?(view, "#thread-#{id} .thread__actions button", "reopen")

    [%{id: reply_id}] = Comments.fetch(id) |> then(fn {:ok, thread} -> thread.replies end)

    view
    |> element("#thread-#{id} .comment__delete[phx-value-reply='#{reply_id}']")
    |> render_click()

    assert has_element?(view, "#thread-#{id} .comment__body", body)
    refute has_element?(view, "#thread-#{id} .comment__body", reply)

    view |> element("#thread-#{id} .comment__delete") |> render_click()

    refute has_element?(view, "#thread-#{id}")
  end

  test "a blank body keeps the composer rather than writing an empty comment", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)

    view |> element("#card-1 .line[data-line='10'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => "   "}) |> render_submit()

    assert has_element?(view, "#card-1 form.composer input[name='line'][value='10']")
    refute has_element?(view, "#card-1 .line[data-line='10'] + .thread")
  end

  test "a comment whose line no longer reads as it did is kept in the card's footer", %{
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("written against a line that has moved")

    {:ok, thread} =
      Comments.add(%{
        function_id: @greet,
        side: "new",
        line: 7,
        body: body,
        author: "human",
        snippet: "def greet(name, shouted?) do"
      })

    assert has_element?(view, "#card-1 footer.card__outdated #thread-#{thread.id}")

    assert has_element?(
             view,
             "#thread-#{thread.id}.thread--outdated .thread__snippet",
             "Outdated · L7"
           )

    refute has_element?(view, "#card-1 .line[data-line='7'] + .thread")
  end

  test "comments belong to the project, so another session shows them", %{
    conn: conn,
    view: view,
    name: name
  } do
    Session.open_root(name, @greet)
    body = unique("the wrap call is the interesting one")

    view |> element("#card-1 .line[data-line='9'] .ln") |> render_click()
    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    other_name = "c-#{System.unique_integer([:positive])}"
    {:ok, other, _html} = live(conn, "/s/#{other_name}")
    Session.open_root(other_name, @greet)

    assert has_element?(other, "#card-1 .thread .comment__body", body)
    refute has_element?(other, "#card-1 form.composer")
  end

  test "a line the branch deleted takes a comment on the base side", %{view: view, name: name} do
    Session.open_root(name, @shout)
    body = unique("this is the clause that went")

    view |> element("#card-1 .line[data-op='del'] .ln") |> render_click()

    assert has_element?(view, "#card-1 form.composer input[name='side'][value='old']")
    assert has_element?(view, "#card-1 form.composer input[name='line'][value='3']")

    view |> form("#card-1 form.composer", %{"body" => body}) |> render_submit()

    id = thread_id(body)
    assert has_element?(view, "#card-1 .line[data-op='del'] + #thread-#{id}")
  end

  defp unique(text), do: "#{text} ##{System.unique_integer([:positive])}"

  defp thread_id(body) do
    thread = Enum.find(Comments.list(include_resolved: true), &(&1.body == body))
    assert thread, "no thread was written with the body #{inspect(body)}"
    thread.id
  end

  # Where two strings fall in the rendered page, which is how a thread is shown to hang off
  # the line above it without depending on what other threads the store happens to hold.
  defp before?(html, first, second) do
    case {:binary.match(html, first), :binary.match(html, second)} do
      {{at, _length}, {then, _then_length}} -> at < then
      _missing -> false
    end
  end
end
