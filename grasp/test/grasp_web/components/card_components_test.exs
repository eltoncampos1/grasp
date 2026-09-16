defmodule GraspWeb.CardComponentsTest do
  # The atom-table assertion below counts atoms process-globally, so it only holds while no
  # other test is running.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Grasp.Session.Forest
  alias GraspWeb.CardComponents

  @wrap "SampleApp.Formatter.wrap/1"
  @whisper "SampleApp.Formatter.whisper/1"

  describe "card/1" do
    test "links a card's file and line into the editor" do
      html = render_card(@wrap)

      assert html =~
               ~s|<a class="card__file" href="vscode://file//tmp/sample_app/lib/sample_app/formatter.ex:4">|

      assert html =~ "lib/sample_app/formatter.ex:4"
    end

    test "a removed function's file is plain text, since the line is the base commit's" do
      html = render_card(@whisper)

      assert html =~ ~s|<span class="card__file">|
      refute html =~ "vscode://"
    end
  end

  describe "signature/1" do
    test "takes the definition line, past the docs above it and without its trailing do" do
      record = %{
        "id" => "SampleApp.Runner.run/1",
        "source" => """
          @doc "Runs the thing."
          @spec run(term()) :: :ok
          def run(x) do
            :ok
          end\
        """
      }

      assert CardComponents.signature(record) == "def run(x)"
    end

    test "a head spread over several lines is cut at the first of them" do
      head = ~S|  def handle("rename", %{"name" => name}, socket),|
      record = %{"id" => "M.handle/3", "source" => head <> "\n    do: {:noreply, socket}"}

      assert CardComponents.signature(record) == String.trim_leading(head)
    end

    test "falls back to the function id when no line defines anything" do
      record = %{"id" => "SampleApp.Runner.run/1", "source" => "  # nothing to see\n  :ok"}

      assert CardComponents.signature(record) == "SampleApp.Runner.run/1"
    end

    test "reads the base commit's text when the record carries no source of its own" do
      record = %{
        "id" => "SampleApp.Formatter.whisper/1",
        "removed" => true,
        "base_source" => "  defp whisper(text) do\n    text\n  end"
      }

      assert CardComponents.signature(record) == "defp whisper(text)"
    end

    test "recognises every form that defines a function" do
      for keyword <- ~w(def defp defmacro defmacrop defguard defguardp defdelegate) do
        record = %{"id" => "M.f/1", "source" => "  #{keyword} f(x)"}

        assert CardComponents.signature(record) == "#{keyword} f(x)"
      end
    end
  end

  describe "hexdocs_url/1" do
    test "links a standard-library function to its documentation" do
      assert CardComponents.hexdocs_url("Enum.map/2") ==
               "https://hexdocs.pm/elixir/Enum.html#map/2"
    end

    test "returns nil for an unknown module without minting its atom" do
      # The first call in the VM loads the modules behind it, and lazy code loading mints its
      # own atoms; both branches are walked once so the measured call only does the lookup.
      CardComponents.hexdocs_url("Zzz.NotARealModule#{System.unique_integer([:positive])}.foo/1")
      CardComponents.hexdocs_url("Enum.map/2")

      id = "Zzz.NotARealModule#{System.unique_integer([:positive])}.foo/1"

      before = :erlang.system_info(:atom_count)
      assert CardComponents.hexdocs_url(id) == nil
      assert :erlang.system_info(:atom_count) == before
    end

    test "returns nil for a module outside the standard library and for a malformed id" do
      assert CardComponents.hexdocs_url("GraspWeb.CardComponents.hexdocs_url/1") == nil
      assert CardComponents.hexdocs_url("not a function id") == nil
    end

    test "returns nil for anything that is not a string" do
      assert CardComponents.hexdocs_url(123) == nil
      assert CardComponents.hexdocs_url(%{"id" => "Enum.map/2"}) == nil
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

  defp render_card(function_id) do
    {forest, _id} = Forest.open_root(Forest.new(), function_id)

    render_component(&CardComponents.card/1,
      forest: forest,
      index: Grasp.IndexStore.get(),
      card: Forest.card(forest, 1),
      column: 0,
      open_calls: %{},
      editor: "vscode"
    )
  end
end
