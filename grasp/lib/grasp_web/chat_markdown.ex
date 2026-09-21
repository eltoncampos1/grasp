defmodule GraspWeb.ChatMarkdown do
  @moduledoc """
  Renders an assistant turn's text — Markdown written by a model — as safe HTML.

  The text is parsed as GitHub-flavoured Markdown (tables, strikethrough, task lists,
  autolinks) and rewritten in two places before it is serialised:

    * a fenced block becomes a `pre.fence` whose body is highlighted by Lumis under the
      language the fence names, so a snippet quoted in the chat reads like the card it was
      taken from. A fence whose language Lumis does not know, and a fence with no language
      at all, is escaped and rendered plain;
    * a `Mod.fun/arity` the index holds becomes a `button.fn` firing `open_root`, whether it
      was written in backticks or bare in a sentence, so naming a function in an answer is
      the same gesture as clicking a call site. An id the index does not hold is left as the
      code span or the prose it was written as, since a button that opens nothing is worse
      than no button.

  Everything the model writes is untrusted: the serialised HTML passes through MDEx's
  sanitiser with an explicit allow-list, which drops `script` and `style` along with their
  content, every `on*` handler and every URL scheme outside the list — so the only markup
  that survives is what this module put there and the tags the allow-list names.
  """

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]

  # A written id is `Mod.fun/arity`, possibly nested (`A.B.fun/1`) and possibly a predicate
  # or a bang. In prose the same body must not start inside a longer name, so a match is
  # refused after a word character or a dot.
  @function_id ~r{\A(?:[A-Z]\w*\.)+[a-z_]\w*[?!]?/\d+\z}
  @function_id_in_text ~r{(?<![\w.])(?:[A-Z]\w*\.)+[a-z_]\w*[?!]?/\d+}

  # Fence info strings Lumis does not answer to under the name a writer reaches for.
  @language_aliases %{
    "ex" => "elixir",
    "exs" => "elixir",
    "erl" => "erlang",
    "sh" => "bash",
    "shell" => "bash",
    "console" => "bash"
  }

  @languages_key {__MODULE__, :languages}

  @doc """
  The Markdown in `text` as sanitised HTML.

  `known?` decides which function ids become buttons: it is given an id exactly as the text
  wrote it and answers whether the index holds a function under it, following the arities a
  default argument declares.
  """
  @spec render(String.t(), (String.t() -> boolean())) :: Phoenix.HTML.safe()
  def render(text, known?) when is_binary(text) and is_function(known?, 1) do
    html =
      text
      |> MDEx.parse_document!(extension: @extension)
      |> MDEx.traverse_and_update(&rewrite(&1, known?))
      |> MDEx.to_html!(render: [unsafe: true], sanitize: allow_list())

    {:safe, html}
  end

  defp rewrite(%MDEx.CodeBlock{info: info, literal: code}, _known?),
    do: %MDEx.HtmlBlock{literal: fence_html(info, code)}

  defp rewrite(%MDEx.Code{literal: id} = node, known?) do
    if function_id?(id) and known?.(id), do: %MDEx.HtmlInline{literal: link_html(id)}, else: node
  end

  defp rewrite(%MDEx.Text{literal: text} = node, known?), do: link_prose(node, text, known?)

  defp rewrite(node, _known?), do: node

  # A Text node is replaced whole rather than split in place: the traversal maps one node to
  # one node, so the linked ids and the text around them are handed back as a single run of
  # inline HTML, with everything that is not an id escaped as it was written.
  defp link_prose(node, text, known?) do
    parts = Regex.split(@function_id_in_text, text, include_captures: true)

    if Enum.any?(parts, &linkable?(&1, known?)) do
      literal =
        Enum.map_join(parts, fn part ->
          if linkable?(part, known?), do: link_html(part), else: escape(part)
        end)

      %MDEx.HtmlInline{literal: literal}
    else
      node
    end
  end

  defp linkable?(text, known?), do: function_id?(text) and known?.(text)

  defp function_id?(text), do: Regex.match?(@function_id, text)

  defp link_html(id) do
    escaped = escape(id)

    ~s(<button type="button" class="fn" phx-click="open_root" phx-value-id="#{escaped}">#{escaped}</button>)
  end

  # Lumis answers for a language it does not know by highlighting nothing rather than by
  # failing, so the language is resolved before the call and an unresolved fence is escaped
  # instead. The highlighter returns a `pre > code` of its own; only its lines are kept, so
  # the fence carries this panel's class and the language it was rendered under.
  defp fence_html(info, code) do
    case language(info) do
      nil ->
        "<pre><code>#{escape(code)}</code></pre>"

      language ->
        case highlighted_lines(code, language) do
          {:ok, lines} ->
            ~s(<pre class="fence" data-lang="#{escape(language)}"><code>#{lines}</code></pre>)

          :error ->
            "<pre><code>#{escape(code)}</code></pre>"
        end
    end
  end

  defp highlighted_lines(code, language) do
    case Lumis.highlight(code, formatter: {:html_linked, language: language}) do
      {:ok, html} ->
        {:ok,
         html
         |> LazyHTML.from_fragment()
         |> LazyHTML.query("pre > code")
         |> LazyHTML.child_nodes()
         |> LazyHTML.to_html()}

      _other ->
        :error
    end
  rescue
    _error -> :error
  end

  # The language the fence's info string names, or nil when the highlighter has no grammar
  # for it. Only the first word counts: a fence may carry attributes after its language.
  defp language(info) do
    name =
      info
      |> to_string()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> String.downcase()

    name = Map.get(@language_aliases, name, name)

    if MapSet.member?(languages(), name), do: name
  end

  # Every grammar name Lumis answers to, held in persistent term: the list is fixed for the
  # life of the node and a transcript re-renders on every line the CLI prints.
  defp languages do
    case :persistent_term.get(@languages_key, nil) do
      nil ->
        names =
          Lumis.available_languages()
          |> Enum.flat_map(&[&1.id | List.wrap(&1.aliases)])
          |> MapSet.new()

        :persistent_term.put(@languages_key, names)
        names

      names ->
        names
    end
  end

  # The sanitiser's own defaults, widened by exactly what this module emits: the `button`
  # that opens a card, the `data-lang` naming a fence's grammar, and the disabled checkbox a
  # task list draws — an `input` allowed nothing but its state, in a panel that has no form
  # to submit it to. Highlighted code is `div`s and `span`s carrying a class, which the
  # defaults already allow; `style` is taken back off them, since nothing here emits one and
  # a panel floating over the canvas is a place inline CSS could be aimed at.
  defp allow_list do
    MDEx.Document.default_sanitize_options()
    |> Keyword.put(:add_tags, ["button", "input"])
    |> Keyword.put(:add_tag_attributes, %{
      "button" => ["type", "class", "phx-click", "phx-value-id"],
      "input" => ["type", "checked", "disabled"],
      "pre" => ["class", "data-lang"],
      "code" => ["class"],
      "div" => ["class"],
      "span" => ["class"]
    })
    |> Keyword.put(:rm_tag_attributes, %{
      "div" => ["style"],
      "pre" => ["style"],
      "span" => ["style"]
    })
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
