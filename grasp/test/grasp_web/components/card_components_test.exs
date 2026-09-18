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

    test "the signature is syntax-highlighted, so a far-out card still reads as code" do
      html = render_card(@wrap)

      assert html =~ ~s|<p class="card__signature lumis"|
      assert html =~ ~s|<span class="l-keyword-function">def</span>|
      assert html =~ ~s|<span class="l-function">wrap</span>|
    end

    test "the body is a block of lines rather than a single preformatted run of text" do
      html = render_card(@wrap)

      assert html =~ ~s|<div class="card__body lumis"|
      refute html =~ "<pre class=\"card__body"
    end

    test "the gutter is sized to the widest line number the body prints" do
      assert render_card(@wrap) =~ ~s|style="--gutter: 4ch"|
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

  describe "changes only" do
    test "a long diff folds its unchanged stretches and the header offers every line" do
      html = render_long_card()

      assert html =~ ~s|data-context="hunks"|
      assert html =~ ~s|<button class="line line--fold"|
      assert html =~ "phx-click=\"expand_fold\""
      assert html =~ "unchanged lines"
      assert html =~ "all lines"

      # The change and the three lines on either side of it are drawn; what sits further out
      # is behind a fold.
      assert html =~ ">a57</span>"
      assert html =~ ">a63</span>"
      refute html =~ ">a20</span>"
    end

    test "a fold the reader opened draws its lines again" do
      html = render_long_card(expanded_folds: MapSet.new([{1, 1}]))

      assert html =~ ">a20</span>"
      # Only the fold that was opened: the one past the change is still a row.
      assert html =~ ~s|<button class="line line--fold"|
    end

    test "a thread holds every line of its range open through a fold" do
      thread = %{
        id: 1,
        function_id: "SampleApp.Long.long/1",
        side: "new",
        line: 20,
        end_line: 23,
        snippet: "a19 = x",
        body: "this run of assignments says nothing",
        author: "human",
        created_at: "2026-09-17T00:00:00Z",
        resolved: false,
        github: nil,
        replies: []
      }

      html = render_long_card(comments: %{"SampleApp.Long.long/1" => [thread]})

      for n <- 19..22, do: assert(html =~ ">a#{n}</span>")
      assert html =~ ~s|<button class="line line--fold"|

      # The thread hangs off the last line of its range, and every line of it is tinted.
      assert html =~ ~s|data-line="23" data-commented="true"|
      assert html =~ ~s|data-line="20" data-commented="true"|
      refute html =~ ~s|data-line="24" data-commented|
      assert before?(html, ~s|data-line="23"|, ~s|id="thread-1"|)
    end

    test "every line is drawn once the card is told to show them all" do
      html = render_long_card(context: :full)

      assert html =~ ~s|data-context="full"|
      refute html =~ "line--fold"
      assert html =~ ">a20</span>"
      assert html =~ "changes only"
    end
  end

  # A modified function long enough that `:auto` folds it, which the fixture has none of.
  defp render_long_card(opts \\ []) do
    body = for n <- 1..118, do: "  a#{n} = x"
    source = Enum.join(["def long(x) do" | body] ++ ["end"], "\n")
    base_source = String.replace(source, "  a60 = x", "  a60 = nil")

    record = %{
      "id" => "SampleApp.Long.long/1",
      "module" => "SampleApp.Long",
      "name" => "long",
      "arity" => 1,
      "kind" => "def",
      "file" => "lib/sample_app/long.ex",
      "span" => %{"start_line" => 1, "end_line" => 120},
      "source" => source,
      "base_source" => base_source,
      "change" => "modified",
      "calls" => [],
      "hidden_calls" => []
    }

    {:ok, index} =
      Grasp.Index.from_document(%{
        "version" => 1,
        "project" => %{"root" => "/tmp/sample_app"},
        "functions" => [record]
      })

    {forest, id} = Forest.open_root(Forest.new(), record["id"])

    forest =
      case Keyword.get(opts, :context) do
        nil -> forest
        context -> Forest.set_context(forest, id, context)
      end

    render_component(&CardComponents.card/1,
      forest: forest,
      index: index,
      card: Forest.card(forest, id),
      column: 0,
      open_calls: %{},
      editor: "vscode",
      expanded_folds: Keyword.get(opts, :expanded_folds),
      comments: Keyword.get(opts, :comments, %{})
    )
  end

  # Where two strings fall in the rendered card, which is how a thread is shown to hang off
  # the line above it.
  defp before?(html, first, second) do
    case {:binary.match(html, first), :binary.match(html, second)} do
      {{at, _length}, {then, _then_length}} -> at < then
      _missing -> false
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
