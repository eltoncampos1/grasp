defmodule SampleApp.Audited do
  @moduledoc "A function whose definition carries a decorator attribute."
  Module.register_attribute(__MODULE__, :decorate, accumulate: true)

  @doc "Leaves a trail behind a greeting."
  @spec leave_trail(String.t()) :: String.t()
  @decorate :trace
  def leave_trail(name), do: SampleApp.Greeter.greet(name)
end
