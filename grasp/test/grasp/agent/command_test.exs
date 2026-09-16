defmodule Grasp.Agent.CommandTest do
  use ExUnit.Case, async: true

  alias Grasp.Agent.Command

  @opts [
    command: "claude",
    session: "s1",
    mcp_url: "http://127.0.0.1:4040/mcp",
    resume: nil,
    model: nil
  ]

  test "build/2 puts the prompt, the stream format and the MCP config first" do
    assert {"claude", argv} = Command.build("hi", @opts)

    assert [
             "-p",
             "hi",
             "--output-format",
             "stream-json",
             "--verbose",
             "--strict-mcp-config",
             "--mcp-config",
             json | rest
           ] = argv

    assert Jason.decode!(json)["mcpServers"]["grasp"] == %{
             "type" => "http",
             "url" => "http://127.0.0.1:4040/mcp"
           }

    assert ["--tools", "Read,Grep,Glob" | rest] = rest
    assert ["--allowedTools", "mcp__grasp,Read,Grep,Glob" | rest] = rest
    assert ["--max-turns", "60" | rest] = rest
    assert ["--append-system-prompt", system_prompt] = rest
    assert system_prompt =~ ~s(session: "s1")
    refute "--resume" in argv
    refute "--model" in argv
  end

  test "build/2 appends resume and model when they are set" do
    {"claude", argv} = Command.build("hi", Keyword.merge(@opts, resume: "abc", model: "opus"))

    assert Enum.take(argv, -4) == ["--resume", "abc", "--model", "opus"]
  end

  test "build/2 appends the model alone when there is nothing to resume" do
    {"claude", argv} = Command.build("hi", Keyword.put(@opts, :model, "opus"))

    assert Enum.take(argv, -2) == ["--model", "opus"]
    refute "--resume" in argv
  end

  test "system_prompt/1 names the session the agent must pass to every card tool" do
    prompt = Command.system_prompt("s1")

    assert prompt =~ "Grasp"
    assert prompt =~ ~s(The Grasp viewer session you control is "s1".)
    assert prompt =~ "set_cards"
  end

  test "system_prompt/1 asks for a group per flow when several flows are wanted" do
    prompt = Command.system_prompt("s1")

    assert prompt =~ "When the user asks for several flows at once, give each flow its own group"
    assert prompt =~ "`group` field"
  end

  test "system_prompt/1 sends a question about a change through list_changes" do
    prompt = Command.system_prompt("s1")

    assert prompt =~ "list_changes"
    assert prompt =~ "find_paths"
  end

  test "mcp_url/0 points at the configured endpoint port" do
    assert Command.mcp_url() == "http://127.0.0.1:4041/mcp"
  end

  test "cwd/0 falls back to the current directory when the indexed root is gone" do
    assert File.dir?("/tmp/sample_app") == false, "the fixture root must not exist"
    assert Command.cwd() == File.cwd!()
  end
end
