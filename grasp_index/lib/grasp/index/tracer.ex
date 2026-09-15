defmodule Grasp.Index.Tracer do
  @moduledoc """
  Compiler tracer that records every call the Elixir compiler resolves while a project
  compiles.

  Registered through `Code.put_compiler_option(:tracers, ...)` before compilation. The
  compiler calls `trace/2` from many processes in parallel, so events go into a public
  named ETS table created by `start/0` and are read back with `events/0`. Only calls
  made inside a function body are recorded: `env.function` is `nil` while a module body
  is being expanded (`use`, attributes, `def` registration), and those events describe
  compilation rather than the program.
  """

  @table :grasp_index_tracer_events

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

  @doc "Creates the event table, replacing any left over from a previous run."
  @spec start() :: :ok
  def start do
    stop()
    :ets.new(@table, [:duplicate_bag, :public, :named_table])
    :ok
  end

  @doc "Deletes the event table if it exists."
  @spec stop() :: :ok
  def stop do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  @doc "Returns every event recorded since `start/0`."
  @spec events() :: [event()]
  def events do
    @table |> :ets.tab2list() |> Enum.map(fn {:event, event} -> event end)
  end

  @doc false
  def trace({kind, meta, module, name, arity}, %Macro.Env{function: {_, _}} = env)
      when kind in [:remote_function, :imported_function, :remote_macro, :imported_macro] do
    record(env, meta, {module, name, arity}, kind_of(kind))
  end

  def trace({kind, meta, name, arity}, %Macro.Env{function: {_, _}} = env)
      when kind in [:local_function, :local_macro] do
    record(env, meta, {env.module, name, arity}, kind_of(kind))
  end

  def trace(_event, _env), do: :ok

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
    end

    :ok
  end

  defp kind_of(:remote_function), do: :remote
  defp kind_of(:local_function), do: :local
  defp kind_of(:imported_function), do: :imported
  defp kind_of(:remote_macro), do: :remote_macro
  defp kind_of(:local_macro), do: :local_macro
  defp kind_of(:imported_macro), do: :imported_macro
end
