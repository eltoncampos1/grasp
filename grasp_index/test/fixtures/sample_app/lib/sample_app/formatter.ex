defmodule SampleApp.Formatter do
  @moduledoc "String decorations used by the greeter."

  @doc "Wraps text in brackets."
  @spec wrap(String.t()) :: String.t()
  def wrap(text), do: "[" <> text <> "]"

  @doc "Upcases text and adds an exclamation mark."
  @spec shout(String.t()) :: String.t()
  def shout(text), do: String.upcase(text) <> "!"
end
