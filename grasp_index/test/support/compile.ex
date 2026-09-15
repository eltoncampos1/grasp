defmodule Grasp.TestSupport.Compile do
  @moduledoc """
  Compiles a source string with `Grasp.Index.Tracer` attached and returns the events,
  restoring the global compiler options afterwards and purging the compiled modules so
  tests can reuse module names.
  """

  @doc "Trace-compiles `source` as if it lived at `file`; returns the tracer events."
  @spec trace(String.t(), String.t()) :: [Grasp.Index.Tracer.event()]
  def trace(source, file) do
    previous_tracers = Code.get_compiler_option(:tracers)
    previous_parser = Code.get_compiler_option(:parser_options)
    Grasp.Index.Tracer.start()
    Code.put_compiler_option(:tracers, [Grasp.Index.Tracer | previous_tracers])
    Code.put_compiler_option(:parser_options, Keyword.put(previous_parser, :columns, true))

    try do
      modules = Code.compile_string(source, file)
      events = Grasp.Index.Tracer.events()

      for {module, _bytecode} <- modules do
        :code.purge(module)
        :code.delete(module)
      end

      events
    after
      Code.put_compiler_option(:tracers, previous_tracers)
      Code.put_compiler_option(:parser_options, previous_parser)
      Grasp.Index.Tracer.stop()
    end
  end
end
