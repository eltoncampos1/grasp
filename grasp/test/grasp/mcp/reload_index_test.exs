defmodule Grasp.MCP.Tools.ReloadIndexTest do
  # A successful reload broadcasts `:index_reloaded` to every mounted view, which recomputes
  # its sidebar defaults and empties its selection, so this must not run beside them.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Grasp.Index
  alias Grasp.IndexStore
  alias Grasp.MCP.Tools

  defp json!(%Response{content: [%{"type" => "text", "text" => text}]}), do: Jason.decode!(text)

  test "re-reads the watched file and reports what it now holds" do
    {:reply, resp, _frame} = Tools.ReloadIndex.execute(%{}, %Frame{})

    refute resp.isError
    body = json!(resp)

    index = IndexStore.get()

    assert body["path"] == IndexStore.path()
    assert body["functions"] == length(Index.functions(index))
    assert body["changed"] == length(Index.changed_functions(index))
    assert body["changed"] > 0
    assert body["base_ref"] == "main"
  end
end
