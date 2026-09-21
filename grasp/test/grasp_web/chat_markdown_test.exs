defmodule GraspWeb.ChatMarkdownTest do
  use ExUnit.Case, async: true

  alias GraspWeb.ChatMarkdown

  @greeter "SampleApp.Greeter.greet/2"

  defp render(text, known \\ [@greeter]) do
    text
    |> ChatMarkdown.render(&(&1 in known))
    |> Phoenix.HTML.safe_to_string()
  end

  test "Markdown emphasis becomes markup" do
    assert render("Reads the **whole** flow.") =~ "<strong>whole</strong>"
  end

  test "a fenced block is highlighted under its language" do
    html = render("```elixir\nIO.puts(:hi)\n```")

    assert html =~ ~s(<pre class="fence" data-lang="elixir">)
    assert html =~ ~s(<code>)
    assert html =~ ~s(class="l-)
  end

  test "a fence in a language the highlighter does not know is escaped plain text" do
    html = render("```wingdings\na <b> & c\n```")

    assert html =~ ~s(<pre><code>)
    assert html =~ "a &lt;b&gt; &amp; c"
    refute html =~ "<b>"
  end

  test "a fence with no language is escaped plain text" do
    assert render("```\n<b>x</b>\n```") =~ "&lt;b&gt;x&lt;/b&gt;"
  end

  test "an inline function id the index holds becomes a card button" do
    html = render("See `#{@greeter}` for the greeting.")

    assert html =~
             ~s(<button type="button" class="fn" phx-click="open_root" phx-value-id="#{@greeter}">#{@greeter}</button>)
  end

  test "an inline function id the index does not hold stays code" do
    html = render("See `Nope.Missing.fun/1` for nothing.")

    assert html =~ "<code>Nope.Missing.fun/1</code>"
    refute html =~ "button"
  end

  test "a bare function id in prose becomes a card button" do
    html = render("The caller is #{@greeter} and it delegates.")

    assert html =~ ~s(phx-value-id="#{@greeter}")
    assert html =~ "The caller is <button"
    assert html =~ "</button> and it delegates."
  end

  test "prose around an unknown id is left alone" do
    html = render("Neither #{@greeter} nor Nope.Missing.fun/1 here.")

    assert html =~ ~s(phx-value-id="#{@greeter}")
    assert html =~ "nor Nope.Missing.fun/1 here."
  end

  test "a function id inside a fence is code, not a button" do
    html = render("```elixir\n#{@greeter}\n```")

    refute html =~ "<button"
    refute html =~ "open_root"
  end

  test "an id written against a default-argument arity follows the index" do
    html = render("Call `SampleApp.Greeter.greet/1`.", ["SampleApp.Greeter.greet/1"])

    assert html =~ ~s(phx-value-id="SampleApp.Greeter.greet/1")
  end

  test "a script block is stripped with its content" do
    html = render("Before.\n\n<script>alert(1)</script>\n\nAfter.")

    refute html =~ "script"
    refute html =~ "alert(1)"
    assert html =~ "Before."
    assert html =~ "After."
  end

  test "an event handler attribute is stripped" do
    html = render(~s|Text <b onclick="steal()">bold</b> more.|)

    refute html =~ "onclick"
    refute html =~ "steal()"
    assert html =~ "bold"
  end

  test "a javascript href is stripped" do
    html = render("[click](javascript:void)")

    refute html =~ "javascript"
    assert html =~ "click"
  end

  test "an inline style is stripped" do
    html = render(~s|<div style="position:fixed">over everything</div>|)

    refute html =~ "style"
    assert html =~ "over everything"
  end

  test "a link keeps its href and gains a rel" do
    html = render("[docs](https://example.com/docs)")

    assert html =~ ~s(href="https://example.com/docs")
    assert html =~ "noopener"
  end

  test "a table renders as a table" do
    html = render("| a | b |\n| - | - |\n| 1 | 2 |")

    assert html =~ "<table>"
    assert html =~ "<td>1</td>"
  end

  test "a task list renders its checkboxes" do
    html = render("- [x] done\n- [ ] open")

    assert html =~ "checkbox"
  end

  test "text carrying HTML special characters is escaped, not injected" do
    assert render("5 < 6 & 7 > 2") =~ "5 &lt; 6 &amp; 7 &gt; 2"
  end

  test "empty text renders nothing" do
    assert render("") == ""
  end
end
