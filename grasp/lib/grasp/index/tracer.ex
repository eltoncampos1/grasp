defmodule Grasp.Index.Tracer do
  @moduledoc """
  Compiler tracer that records every call the Elixir compiler resolves while a project
  compiles.

  Registered through `Code.put_compiler_option(:tracers, ...)` before compilation. The
  compiler calls `trace/2` from many processes in parallel, so events go into a public
  named ETS table created by `start/0` and are read back with `events/0` or drained with
  `take_events/0`. Only calls made inside a function body are recorded: `env.function` is
  `nil` while a module body is being expanded (`use`, attributes, `def` registration), and
  those events describe compilation rather than the program.

  The table outlives a single compile, because `Grasp.Reindexer` installs the tracer once
  and follows every compile the host's code reloader performs. A process registered under
  `Grasp.Reindexer` is told that events are waiting: each compiler process sends
  `{:events, count}` at most once every 300 ms, so a compile of a thousand files
  costs a handful of messages rather than one per call. The count is what that process
  recorded since its own last message, not the table's size — the reader drains the table
  and does not need it to be exact.

  Nothing the tracer does may fail a compile: `trace/2` swallows every error, so a bug
  here costs events rather than the host's build.
  """

  @table :grasp_index_tracer_events
  @reader Grasp.Reindexer
  @notify_ms 300
  @notified_at_key {__MODULE__, :notified_at}
  @pending_key {__MODULE__, :pending}

  @type kind :: :remote | :local | :imported | :remote_macro | :local_macro | :imported_macro

  @type event :: %{
          file: String.t(),
          module: module(),
          function: {atom(), non_neg_integer()},
          line: pos_integer(),
          column: pos_integer() | nil,
          target: {module(), atom(), non_neg_integer()},
          kind: kind()
        }

  @doc """
  Creates the event table, owned by the calling process.

  Idempotent: a table that is already there is kept, with the events it holds, so a second
  installer does not throw away what the first one recorded.
  """
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:duplicate_bag, :public, :named_table])
    end

    :ok
  end

  @doc "Deletes the event table if it exists."
  @spec stop() :: :ok
  def stop do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  @doc "Returns every event recorded since `start/0`, leaving them in the table."
  @spec events() :: [event()]
  def events do
    @table |> :ets.tab2list() |> Enum.map(fn {:event, event} -> event end)
  end

  @doc """
  Returns every recorded event and removes it from the table.

  Every event shares one key, so the drain is a single atomic `:ets.take/2`: an event
  recorded by a compile still running is either in the batch returned or still in the
  table for the next drain, never lost between the two.
  """
  @spec take_events() :: [event()]
  def take_events do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table |> :ets.take(:event) |> Enum.map(fn {:event, event} -> event end)
    end
  end

  @doc false
  def trace(event, env) do
    record_event(event, env)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp record_event({kind, meta, module, name, arity}, %Macro.Env{function: {_, _}} = env)
       when kind in [:remote_function, :imported_function, :remote_macro, :imported_macro] do
    record(env, meta, {module, name, arity}, kind_of(kind))
  end

  defp record_event({kind, meta, name, arity}, %Macro.Env{function: {_, _}} = env)
       when kind in [:local_function, :local_macro] do
    record(env, meta, {env.module, name, arity}, kind_of(kind))
  end

  defp record_event(_event, _env), do: :ok

  defp record(%Macro.Env{} = env, meta, target, kind) do
    if :ets.whereis(@table) != :undefined do
      event = %{
        file: env.file,
        module: env.module,
        function: env.function,
        line: Keyword.get(meta, :line, env.line),
        column: Keyword.get(meta, :column),
        target: target,
        kind: kind
      }

      :ets.insert(@table, {:event, event})
      notify()
    end

    :ok
  end

  # Throttled in the compiler process rather than centrally: the process dictionary is the
  # one piece of state a tracer can read without a lock, and a compile spawns a process per
  # file, so the reader hears from a busy compile often enough to keep its timer pushed out
  # and rarely enough that the messages cost nothing.
  defp notify do
    pending = (Process.get(@pending_key) || 0) + 1
    now = System.monotonic_time(:millisecond)
    last = Process.get(@notified_at_key)

    if is_nil(last) or now - last >= @notify_ms do
      Process.put(@notified_at_key, now)
      Process.put(@pending_key, 0)
      reader = Process.whereis(@reader)
      if reader, do: send(reader, {:events, pending})
    else
      Process.put(@pending_key, pending)
    end
  end

  defp kind_of(:remote_function), do: :remote
  defp kind_of(:local_function), do: :local
  defp kind_of(:imported_function), do: :imported
  defp kind_of(:remote_macro), do: :remote_macro
  defp kind_of(:local_macro), do: :local_macro
  defp kind_of(:imported_macro), do: :imported_macro
end
