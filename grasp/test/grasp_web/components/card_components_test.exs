defmodule GraspWeb.CardComponentsTest do
  # The atom-table assertion below counts atoms process-globally, so it only holds while no
  # other test is running.
  use ExUnit.Case, async: false

  alias GraspWeb.CardComponents

  describe "hexdocs_url/1" do
    test "links a standard-library function to its documentation" do
      assert CardComponents.hexdocs_url("Enum.map/2") ==
               "https://hexdocs.pm/elixir/Enum.html#map/2"
    end

    test "returns nil for an unknown module without minting its atom" do
      id = "Zzz.NotARealModule#{System.unique_integer([:positive])}.foo/1"

      before = :erlang.system_info(:atom_count)
      assert CardComponents.hexdocs_url(id) == nil
      assert :erlang.system_info(:atom_count) == before
    end

    test "returns nil for a module outside the standard library and for a malformed id" do
      assert CardComponents.hexdocs_url("GraspWeb.CardComponents.hexdocs_url/1") == nil
      assert CardComponents.hexdocs_url("not a function id") == nil
    end
  end

  describe "editor_url/4" do
    test "returns nil without an editor or without a project root" do
      assert CardComponents.editor_url(nil, "/tmp/app", "lib/a.ex", 1) == nil
      assert CardComponents.editor_url("vscode", nil, "lib/a.ex", 1) == nil
      assert CardComponents.editor_url("emacs", "/tmp/app", "lib/a.ex", 1) == nil
    end

    test "percent-encodes path segments but keeps the separators" do
      assert CardComponents.editor_url("vscode", "/tmp/my app", "lib/a b.ex", 7) ==
               "vscode://file//tmp/my%20app/lib/a%20b.ex:7"
    end

    test "encodes the idea link as a query value" do
      assert CardComponents.editor_url("idea", "/tmp/a&b", "lib/a.ex", 3) ==
               "idea://open?file=%2Ftmp%2Fa%26b%2Flib%2Fa.ex&line=3"
    end
  end
end
