defmodule SampleApp.Greeter do
  @moduledoc "Greets people, exercising aliases, imports, defaults, captures and nesting."
  alias SampleApp.Formatter
  import SampleApp.Formatter, only: [shout: 1]

  @doc "Greets someone, loudly if asked."
  @spec greet(String.t(), boolean()) :: String.t()
  def greet(name, loud? \\ false) do
    text = Formatter.wrap(name)
    if loud?, do: shout(text), else: text
  end

  @doc "Greets everyone."
  @spec greet_all([String.t()]) :: [String.t()]
  def greet_all(names), do: Enum.map(names, &greet/1)

  defmodule Nested do
    @moduledoc "A nested module calling back into its parent."

    @doc "Greets from inside."
    @spec hello() :: String.t()
    def hello, do: SampleApp.Greeter.greet("nested")
  end
end
