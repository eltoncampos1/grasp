defmodule Grasp.MCP.CommentToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools

  @greet "SampleApp.Greeter.greet/2"
  @shout "SampleApp.Formatter.shout/1"

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  defp run(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end

  # The store is shared by the whole suite, so a test recognises its own threads by a body
  # no other test writes and never counts what the listing holds.
  defp unique_body, do: "mcp comment #{System.unique_integer([:positive])}"

  defp add(params), do: json!(run(Tools.AddComment, params))

  defp listed(params), do: json!(run(Tools.ListComments, params))

  defp find(body, id), do: Enum.find(body["comments"], &(&1["id"] == id))

  defp message(%Response{isError: true, content: [%{"text" => text}]}), do: text

  describe "add_comment" do
    test "writes a thread the listing shows anchored on its line" do
      body = unique_body()
      thread = add(%{function_id: @greet, line: 9, body: body})

      assert thread["function_id"] == @greet
      assert thread["author"] == "agent"
      assert thread["side"] == "new"
      assert thread["line"] == 9
      assert thread["status"] == "anchored"
      assert thread["anchored_line"] == 9
      assert thread["file"] == "lib/sample_app/greeter.ex"
      assert thread["snippet"] == "text = Formatter.wrap(name)"
      assert thread["resolved"] == false
      assert thread["replies"] == []

      found = find(listed(%{function_id: @greet}), thread["id"])
      assert found["body"] == body
      assert found["status"] == "anchored"
      assert found["anchored_line"] == 9
    end

    test "stores the thread under the canonical id of the function named" do
      thread = add(%{function_id: "SampleApp.Greeter.greet/1", body: unique_body(), line: 8})

      assert thread["function_id"] == @greet
      assert find(listed(%{function_id: @greet}), thread["id"])
    end

    test "writes on the base version of a modified function" do
      thread = add(%{function_id: @shout, side: "old", line: 3, body: unique_body()})

      assert thread["side"] == "old"
      assert thread["status"] == "anchored"
      assert thread["anchored_line"] == 3
      assert thread["snippet"] == "def shout(text), do: text"
    end

    test "a line outside the function is an error naming the range" do
      response = run(Tools.AddComment, %{function_id: @greet, line: 99, body: unique_body()})

      assert response.isError
      assert message(response) == "line 99 is outside #{@greet} (lines 6..11)"
    end

    test "the old side of a function the branch left alone is an error" do
      response =
        run(Tools.AddComment, %{function_id: @greet, side: "old", line: 1, body: unique_body()})

      assert response.isError
      assert message(response) =~ "no base version"
    end

    test "a blank body is an error" do
      response = run(Tools.AddComment, %{function_id: @greet, line: 9, body: "   "})

      assert response.isError
      assert message(response) == "body must not be blank"
    end

    test "a side that is neither new nor old is an error" do
      response =
        run(Tools.AddComment, %{function_id: @greet, side: "both", line: 9, body: unique_body()})

      assert response.isError
      assert message(response) =~ ~s(side must be "new" or "old")
    end

    test "an unknown function is an error" do
      response =
        run(Tools.AddComment, %{function_id: "SampleApp.Nope.nope/0", line: 1, body: "x"})

      assert response.isError
      assert message(response) == "unknown function: SampleApp.Nope.nope/0"
    end
  end

  describe "reply_comment" do
    test "appends the agent's reply to the thread" do
      thread = add(%{function_id: @greet, line: 11, body: unique_body()})
      answer = unique_body()

      replied = json!(run(Tools.ReplyComment, %{comment_id: thread["id"], body: answer}))

      assert replied["id"] == thread["id"]
      assert [%{"author" => "agent", "body" => ^answer}] = replied["replies"]
      assert find(listed(%{function_id: @greet}), thread["id"])["replies"] |> length() == 1
    end

    test "an unknown thread is an error" do
      response = run(Tools.ReplyComment, %{comment_id: 987_654, body: "hello"})

      assert response.isError
      assert message(response) == "unknown comment: 987654"
    end
  end

  describe "resolve_comment" do
    test "takes the thread off the open list and puts it back" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})
      id = thread["id"]

      resolved = json!(run(Tools.ResolveComment, %{comment_id: id}))

      assert resolved["resolved"] == true
      refute find(listed(%{function_id: @greet}), id)
      assert find(listed(%{function_id: @greet, include_resolved: true}), id)["resolved"] == true

      reopened = json!(run(Tools.ResolveComment, %{comment_id: id, resolved: false}))

      assert reopened["resolved"] == false
      assert find(listed(%{function_id: @greet}), id)
    end

    test "an unknown thread is an error" do
      response = run(Tools.ResolveComment, %{comment_id: 987_655})

      assert response.isError
      assert message(response) == "unknown comment: 987655"
    end
  end

  describe "list_comments" do
    test "counts what it returns and sorts by id" do
      first = add(%{function_id: @greet, line: 9, body: unique_body()})
      second = add(%{function_id: @greet, line: 11, body: unique_body()})

      body = listed(%{function_id: @greet})
      ids = Enum.map(body["comments"], & &1["id"])

      assert body["total"] == length(body["comments"])
      assert ids == Enum.sort(ids)

      assert Enum.find_index(ids, &(&1 == first["id"])) <
               Enum.find_index(ids, &(&1 == second["id"]))
    end

    test "a function no index knows holds no comments" do
      assert listed(%{function_id: "SampleApp.Nope.nope/0"}) == %{
               "total" => 0,
               "comments" => []
             }
    end
  end

  describe "get_function" do
    test "carries the function's open threads" do
      thread = add(%{function_id: @greet, line: 9, body: unique_body()})

      body = json!(run(Tools.GetFunction, %{id: @greet}))
      carried = Enum.find(body["comments"], &(&1["id"] == thread["id"]))

      assert carried["anchored_line"] == 9

      json!(run(Tools.ResolveComment, %{comment_id: thread["id"]}))
      body = json!(run(Tools.GetFunction, %{id: @greet}))

      refute Enum.find(body["comments"], &(&1["id"] == thread["id"]))
    end
  end

  describe "input schemas" do
    test "name the thread, the line and the body" do
      refute Tools.ListComments.input_schema()["required"]
      assert Enum.sort(Tools.AddComment.input_schema()["required"]) == ~w(body function_id line)
      assert Enum.sort(Tools.ReplyComment.input_schema()["required"]) == ~w(body comment_id)
      assert Tools.ResolveComment.input_schema()["required"] == ["comment_id"]

      # Anubis leaves a field's default out of the JSON schema, so the description carries it
      assert Tools.ListComments.input_schema()["properties"]["include_resolved"]["description"] =~
               "default false"
    end
  end
end
