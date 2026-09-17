defmodule Grasp.MCP.PublishCommentsTest do
  # Sets FAKE_GH_LOG, which the whole VM shares, and makes the fixture's project root a
  # directory, which an async test asserts is absent.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.MCP.Tools

  @moduletag :tmp_dir

  @greet "SampleApp.Greeter.greet/2"
  @root "/tmp/sample_app"

  setup %{tmp_dir: tmp_dir} do
    System.put_env("FAKE_GH_LOG", Path.join(tmp_dir, "gh.log"))

    kept = File.dir?(@root)
    File.mkdir_p!(@root)

    on_exit(fn ->
      System.delete_env("FAKE_GH_LOG")
      unless kept, do: File.rm_rf!(@root)
    end)

    :ok
  end

  defp run(tool, params) do
    {:reply, response, _frame} = tool.execute(params, %Frame{})
    response
  end

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  # The store is shared by the whole suite, so a test reads back the thread it opened rather
  # than whatever else the report carries.
  defp unique_body, do: "mcp publish #{System.unique_integer([:positive])}"

  defp published(body, id), do: Enum.find(body["published"], &(&1["comment_id"] == id))

  test "publishes the open threads and reports where each one went" do
    thread = json!(run(Tools.AddComment, %{function_id: @greet, line: 7, body: unique_body()}))

    body = json!(run(Tools.PublishComments, %{}))

    assert body["pull_request"] == %{
             "number" => 42,
             "url" => "https://github.com/acme/sample_app/pull/42"
           }

    assert published(body, thread["id"])["kind"] == "line"
    assert published(body, thread["id"])["url"] =~ "#discussion_r"
    assert is_list(body["skipped"])
    assert is_list(body["failed"])
    assert is_list(body["warnings"])

    listed = json!(run(Tools.ListComments, %{function_id: @greet, include_resolved: true}))
    listed = Enum.find(listed["comments"], &(&1["id"] == thread["id"]))

    assert listed["github_url"] == published(body, thread["id"])["url"]
  end

  test "answers the failure when the branch has no pull request" do
    assert %Response{isError: true, content: [%{"text" => text}]} =
             run(Tools.PublishComments, %{pull_request: 404})

    assert text =~ "no pull requests"
  end

  test "the schema takes a pull request number and a resolved switch, neither required" do
    schema = Tools.PublishComments.input_schema()

    refute schema["required"]
    assert schema["properties"]["pull_request"]["type"] == "integer"
    assert schema["properties"]["include_resolved"]["description"] =~ "default false"
  end
end
