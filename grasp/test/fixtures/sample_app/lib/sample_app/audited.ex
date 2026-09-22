defmodule SampleApp.Audited do
  @moduledoc "A function whose definition carries a decorator attribute."
  Module.register_attribute(__MODULE__, :decorate, accumulate: true)

  @doc "Greets and leaves a trail."
  @spec greet(String.t()) :: String.t()
  @decorate :trace
  def greet(name), do: SampleApp.Greeter.greet(name)
end
