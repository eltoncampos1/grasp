defmodule Grasp.Comments do
  @moduledoc """
  Review comments written on lines of the functions the cards show.

  Comments belong to the project rather than to a session. A session is a working
  arrangement of cards that lives only while the viewer runs, whereas a remark about a
  line is worth keeping: the reviewer closes the card, reopens the project tomorrow, and
  expects the thread to still hang off that line. One store therefore holds every thread
  for the indexed project, and each thread names the function it belongs to, so any
  session that happens to draw that function shows it.

  A thread records the line number it was written on *and* the text of that line, the
  snippet. Code moves under a comment, so the number alone is not an anchor;
  `Grasp.Comments.Anchor` re-places a thread against the current record from the snippet.
  The snippet is captured when the comment is written — `snippet/3` reads it off the
  record — because afterwards the line it describes may be gone.

  Threads and replies draw their ids from a single counter that only ever grows, so an id
  freed by a delete is never handed out again and a client holding a stale id cannot
  address someone else's comment.

  Persistence is a single JSON document beside the index, `.grasp/comments.json` under
  the project root, chosen so comments travel with the checkout and can be read and
  reviewed like any other file. The path can be overridden by `start_link/1` or by the
  `:grasp, :comments_path` setting, and when neither is given and no project root exists
  on disk the store keeps its threads in memory only. The whole document is rewritten
  after every mutation: it is small, and a full rewrite cannot leave a half-applied edit
  behind. A file that cannot be read, parsed or written is a warning and never a crash —
  losing the viewer over a comment file would be a worse failure than losing the file.

  A file the store could not fully read is salvaged rather than discarded: entries it
  cannot decode are skipped and the rest are kept, and the file is renamed to
  `<path>.corrupt` before the next write, so a rewrite never silently replaces a history
  someone still wants. The id counter is likewise recomputed on every read as one past the
  highest id the document holds, so a truncated or hand-edited `next_id` cannot make the
  next comment overwrite an existing one.

  Every successful mutation broadcasts `:comments_changed` on the `"comments"` topic.
  """

  use GenServer

  require Logger

  alias Grasp.Comments.Anchor

  @type author :: String.t()
  @type side :: String.t()
  @type store :: GenServer.server()
  @type reply :: %{id: pos_integer(), author: author(), body: String.t(), created_at: String.t()}
  @type thread :: %{
          id: pos_integer(),
          function_id: String.t(),
          side: side(),
          line: pos_integer(),
          snippet: String.t() | nil,
          body: String.t(),
          author: author(),
          created_at: String.t(),
          resolved: boolean(),
          replies: [reply()]
        }

  @topic "comments"
  @authors ~w(human agent)
  @sides ~w(new old)

  @doc """
  Starts the store.

  `:path` overrides the file to read and write, taking precedence over the
  `:grasp, :comments_path` setting and over the path derived from the project root, and
  `:name` registers the store under a name other than the module, for a second store
  running beside the application's, which `list/2` and `add/2` address by that name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribes the caller to `:comments_changed` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Grasp.PubSub, @topic)

  @doc """
  Threads sorted by id.

  `:function_id` keeps only the threads on that function, and `:include_resolved` (false
  by default) keeps the resolved ones as well. `store` reads a store other than the
  application's.
  """
  @spec list() :: [thread()]
  @spec list(keyword()) :: [thread()]
  @spec list(keyword(), store()) :: [thread()]
  def list(opts \\ [], store \\ __MODULE__) when is_list(opts),
    do: GenServer.call(store, {:list, opts})

  @doc "Every thread, resolved ones included, grouped by function id and sorted by id."
  @spec by_function() :: %{String.t() => [thread()]}
  def by_function, do: GenServer.call(__MODULE__, :by_function)

  @doc "Fetches the thread `id`."
  @spec fetch(pos_integer()) :: {:ok, thread()} | :error
  def fetch(id) when is_integer(id), do: GenServer.call(__MODULE__, {:fetch, id})

  @doc """
  Opens a thread from `%{function_id, side, line, body, author, snippet}`.

  `side` is `"new"` or `"old"`, `author` is `"human"` or `"agent"`, `body` is stored
  trimmed and may not be blank, and `snippet` (optional) is the text of the line as it
  reads when the comment is written. `store` writes to a store other than the
  application's.
  """
  @spec add(map()) :: {:ok, thread()} | {:error, :invalid}
  @spec add(map(), store()) :: {:ok, thread()} | {:error, :invalid}
  def add(attrs, store \\ __MODULE__) when is_map(attrs),
    do: GenServer.call(store, {:add, attrs})

  @doc "Appends a reply `%{body, author}` to the thread `id`, returning the whole thread."
  @spec reply(pos_integer(), map()) :: {:ok, thread()} | {:error, :unknown | :invalid}
  def reply(id, attrs) when is_integer(id) and is_map(attrs),
    do: GenServer.call(__MODULE__, {:reply, id, attrs})

  @doc "Marks the thread `id` resolved or unresolved."
  @spec set_resolved(pos_integer(), boolean()) :: {:ok, thread()} | {:error, :unknown}
  def set_resolved(id, resolved) when is_integer(id) and is_boolean(resolved),
    do: GenServer.call(__MODULE__, {:set_resolved, id, resolved})

  @doc "Deletes the thread `id` and its replies; an unknown id changes nothing."
  @spec delete(pos_integer()) :: :ok
  def delete(id) when is_integer(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "Deletes one reply of a thread; an unknown thread or reply changes nothing."
  @spec delete_reply(pos_integer(), pos_integer()) :: :ok
  def delete_reply(thread_id, reply_id) when is_integer(thread_id) and is_integer(reply_id),
    do: GenServer.call(__MODULE__, {:delete_reply, thread_id, reply_id})

  @doc "The file the threads are written to, or `nil` when they are held in memory only."
  @spec path() :: String.t() | nil
  def path, do: GenServer.call(__MODULE__, :path)

  @doc """
  The trimmed text of line `line` of `record` on `side`, or `nil` when there is no such
  line.

  The `"new"` side is numbered from the record's span, as the cards number it; the
  `"old"` side is numbered from 1, as the diff's base column is.
  """
  @spec snippet(map() | nil, side(), pos_integer()) :: String.t() | nil
  def snippet(record, side, line) do
    case Anchor.lines(record, side) do
      nil ->
        nil

      lines ->
        Enum.find_value(lines, fn {number, text} -> number == line && String.trim(text) end)
    end
  end

  @doc false
  @spec encode([thread()], pos_integer()) :: String.t()
  def encode(threads, next_id) do
    document = %{
      "version" => 1,
      "next_id" => next_id,
      "comments" => Enum.map(threads, &encode_thread/1)
    }

    Jason.encode!(document, pretty: true)
  end

  @doc false
  @spec decode(String.t()) ::
          {:ok, {[thread()], pos_integer(), non_neg_integer()}} | {:error, term()}
  def decode(binary) do
    with {:ok, document} <- Jason.decode(binary),
         {:ok, next_id, comments} <- document_parts(document) do
      {threads, dropped} = decode_threads(comments)
      threads = Enum.sort_by(threads, & &1.id)
      {:ok, {threads, counter(threads, next_id), dropped}}
    end
  end

  @impl true
  def init(opts) do
    :ok = Grasp.IndexStore.subscribe()
    override = Keyword.get(opts, :path) || Application.get_env(:grasp, :comments_path)

    state = %{
      path: override || derived_path(),
      override: not is_nil(override),
      threads: %{},
      next_id: 1,
      corrupt: false
    }

    {:ok, read(state)}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    function_id = Keyword.get(opts, :function_id)
    include_resolved = Keyword.get(opts, :include_resolved, false)

    threads =
      state.threads
      |> sorted()
      |> Enum.filter(fn thread ->
        (is_nil(function_id) or thread.function_id == function_id) and
          (include_resolved or not thread.resolved)
      end)

    {:reply, threads, state}
  end

  def handle_call(:by_function, _from, state),
    do: {:reply, state.threads |> sorted() |> Enum.group_by(& &1.function_id), state}

  def handle_call({:fetch, id}, _from, state), do: {:reply, Map.fetch(state.threads, id), state}

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  def handle_call({:add, attrs}, _from, state) do
    case build_thread(attrs, state.next_id) do
      {:ok, thread} ->
        state = %{
          state
          | threads: Map.put(state.threads, thread.id, thread),
            next_id: state.next_id + 1
        }

        {:reply, {:ok, thread}, commit(state)}

      :error ->
        {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:reply, id, attrs}, _from, state) do
    with {:ok, thread} <- Map.fetch(state.threads, id),
         {:ok, reply} <- build_reply(attrs, state.next_id) do
      thread = %{thread | replies: thread.replies ++ [reply]}

      state = %{
        state
        | threads: Map.put(state.threads, id, thread),
          next_id: state.next_id + 1
      }

      {:reply, {:ok, thread}, commit(state)}
    else
      :error -> {:reply, {:error, reply_error(state, id)}, state}
    end
  end

  def handle_call({:set_resolved, id, resolved}, _from, state) do
    case Map.fetch(state.threads, id) do
      {:ok, %{resolved: ^resolved} = thread} ->
        {:reply, {:ok, thread}, state}

      {:ok, thread} ->
        thread = %{thread | resolved: resolved}
        state = %{state | threads: Map.put(state.threads, id, thread)}
        {:reply, {:ok, thread}, commit(state)}

      :error ->
        {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.threads, id) do
      {nil, _threads} -> {:reply, :ok, state}
      {_thread, threads} -> {:reply, :ok, commit(%{state | threads: threads})}
    end
  end

  def handle_call({:delete_reply, thread_id, reply_id}, _from, state) do
    case Map.fetch(state.threads, thread_id) do
      {:ok, thread} ->
        replies = Enum.reject(thread.replies, &(&1.id == reply_id))

        if replies == thread.replies do
          {:reply, :ok, state}
        else
          thread = %{thread | replies: replies}
          state = %{state | threads: Map.put(state.threads, thread_id, thread)}
          {:reply, :ok, commit(state)}
        end

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:index_reloaded, %{override: true} = state), do: {:noreply, state}

  def handle_info(:index_reloaded, state) do
    case derived_path() do
      path when path == state.path ->
        {:noreply, state}

      path ->
        state = read(%{state | path: path})
        Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :comments_changed)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp commit(state) do
    state = persist(state)
    Phoenix.PubSub.broadcast(Grasp.PubSub, @topic, :comments_changed)
    state
  end

  defp read(%{path: nil} = state), do: empty(state, false)

  defp read(state) do
    case File.read(state.path) do
      {:ok, binary} -> decode_file(binary, state)
      {:error, :enoent} -> empty(state, false)
      {:error, reason} -> empty(log_read_failure(state, reason), true)
    end
  end

  defp decode_file(binary, state) do
    case decode(binary) do
      {:ok, {threads, next_id, 0}} ->
        %{state | threads: Map.new(threads, &{&1.id, &1}), next_id: next_id, corrupt: false}

      {:ok, {threads, next_id, dropped}} ->
        entries = if dropped == 1, do: "entry", else: "entries"
        Logger.warning("grasp: dropped #{dropped} unreadable #{entries} from #{state.path}")

        %{state | threads: Map.new(threads, &{&1.id, &1}), next_id: next_id, corrupt: true}

      {:error, reason} ->
        empty(log_read_failure(state, reason), true)
    end
  end

  defp empty(state, corrupt), do: %{state | threads: %{}, next_id: 1, corrupt: corrupt}

  defp log_read_failure(state, reason) do
    Logger.warning("grasp: could not read comments #{state.path}: #{inspect(reason)}")
    state
  end

  defp persist(%{path: nil} = state), do: state

  defp persist(state) do
    state = keep_corrupt_aside(state)

    case write(state.path, encode(sorted(state.threads), state.next_id)) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("grasp: could not write comments #{state.path}: #{inspect(reason)}")
        state
    end
  end

  defp write(path, document) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, document)
  end

  # Rewriting the document would drop whatever the last read could not decode, so the file
  # it came from is moved aside first and the reviewer keeps a copy to recover by hand.
  defp keep_corrupt_aside(%{corrupt: false} = state), do: state

  # A second damaged file at the same path is kept beside the first rather than over it:
  # `File.rename/2` replaces an existing destination without a word, and the copy it would
  # replace is the one the reader has not looked at yet.
  defp keep_corrupt_aside(state) do
    kept = state.path <> ".corrupt"

    kept =
      if File.exists?(kept),
        do: state.path <> ".#{System.os_time(:second)}.corrupt",
        else: kept

    case File.rename(state.path, kept) do
      :ok -> Logger.warning("grasp: kept the unreadable comments file as #{kept}")
      {:error, reason} -> Logger.warning("grasp: could not keep #{kept}: #{inspect(reason)}")
    end

    %{state | corrupt: false}
  end

  defp derived_path do
    with %Grasp.Index{} = index <- Grasp.IndexStore.get(),
         root when is_binary(root) <- index.project["root"],
         true <- File.dir?(root) do
      Path.join(root, ".grasp/comments.json")
    else
      _no_project_on_disk -> nil
    end
  end

  defp sorted(threads), do: threads |> Map.values() |> Enum.sort_by(& &1.id)

  # One past the highest id the document holds, so a `next_id` that lags behind its own
  # comments — truncated write, hand edit, merge — cannot hand out an id already in use.
  defp counter(threads, next_id) do
    Enum.reduce(threads, max(next_id, 1), fn thread, counter ->
      Enum.reduce(thread.replies, max(counter, thread.id + 1), &max(&2, &1.id + 1))
    end)
  end

  defp reply_error(state, id),
    do: if(Map.has_key?(state.threads, id), do: :invalid, else: :unknown)

  defp build_thread(attrs, id) do
    with {:ok, function_id} <- binary_field(attrs, :function_id),
         {:ok, side} <- member_field(attrs, :side, @sides),
         {:ok, line} <- line_field(attrs),
         {:ok, author} <- member_field(attrs, :author, @authors),
         {:ok, body} <- body_field(attrs) do
      {:ok,
       %{
         id: id,
         function_id: function_id,
         side: side,
         line: line,
         snippet: Map.get(attrs, :snippet),
         body: body,
         author: author,
         created_at: now(),
         resolved: false,
         replies: []
       }}
    end
  end

  defp build_reply(attrs, id) do
    with {:ok, author} <- member_field(attrs, :author, @authors),
         {:ok, body} <- body_field(attrs) do
      {:ok, %{id: id, author: author, body: body, created_at: now()}}
    end
  end

  defp binary_field(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      _invalid -> :error
    end
  end

  defp member_field(attrs, key, allowed) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> if value in allowed, do: {:ok, value}, else: :error
      _invalid -> :error
    end
  end

  defp line_field(attrs) do
    case Map.get(attrs, :line) do
      line when is_integer(line) and line > 0 -> {:ok, line}
      _invalid -> :error
    end
  end

  defp body_field(attrs) do
    case Map.get(attrs, :body) do
      body when is_binary(body) ->
        case String.trim(body) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _invalid ->
        :error
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp encode_thread(thread) do
    %{
      "id" => thread.id,
      "function_id" => thread.function_id,
      "side" => thread.side,
      "line" => thread.line,
      "snippet" => thread.snippet,
      "body" => thread.body,
      "author" => thread.author,
      "created_at" => thread.created_at,
      "resolved" => thread.resolved,
      "replies" => Enum.map(thread.replies, &encode_reply/1)
    }
  end

  defp encode_reply(reply) do
    %{
      "id" => reply.id,
      "author" => reply.author,
      "body" => reply.body,
      "created_at" => reply.created_at
    }
  end

  defp document_parts(%{"version" => 1, "next_id" => next_id, "comments" => comments})
       when is_integer(next_id) and next_id > 0 and is_list(comments),
       do: {:ok, next_id, comments}

  defp document_parts(document), do: {:error, {:invalid_document, document}}

  defp decode_threads(comments) do
    {threads, dropped} =
      Enum.reduce(comments, {[], 0}, fn comment, {threads, dropped} ->
        case decode_thread(comment) do
          {:ok, thread, reply_drops} -> {[thread | threads], dropped + reply_drops}
          :error -> {threads, dropped + 1}
        end
      end)

    {Enum.reverse(threads), dropped}
  end

  defp decode_thread(
         %{
           "id" => id,
           "function_id" => function_id,
           "side" => side,
           "line" => line,
           "body" => body,
           "author" => author,
           "created_at" => created_at
         } = comment
       )
       when is_integer(id) and id > 0 and is_binary(function_id) and is_binary(body) and
              is_binary(created_at) and is_integer(line) and line > 0 and side in @sides and
              author in @authors do
    snippet = Map.get(comment, "snippet")

    if is_nil(snippet) or is_binary(snippet) do
      {replies, dropped} = decode_replies(Map.get(comment, "replies", []))

      {:ok,
       %{
         id: id,
         function_id: function_id,
         side: side,
         line: line,
         snippet: snippet,
         body: body,
         author: author,
         created_at: created_at,
         resolved: Map.get(comment, "resolved") == true,
         replies: replies
       }, dropped}
    else
      :error
    end
  end

  defp decode_thread(_comment), do: :error

  defp decode_replies(replies) when is_list(replies) do
    {decoded, dropped} =
      Enum.reduce(replies, {[], 0}, fn reply, {decoded, dropped} ->
        case decode_reply(reply) do
          {:ok, reply} -> {[reply | decoded], dropped}
          :error -> {decoded, dropped + 1}
        end
      end)

    {Enum.reverse(decoded), dropped}
  end

  defp decode_replies(_replies), do: {[], 1}

  defp decode_reply(%{"id" => id, "author" => author, "body" => body, "created_at" => created_at})
       when is_integer(id) and id > 0 and is_binary(body) and is_binary(created_at) and
              author in @authors,
       do: {:ok, %{id: id, author: author, body: body, created_at: created_at}}

  defp decode_reply(_reply), do: :error
end
