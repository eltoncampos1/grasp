defmodule SampleAppWeb.GreetHTML do
  @moduledoc "The HTML module `SampleAppWeb.GreetController` renders through."
  use Phoenix.Component

  embed_templates "greet_html/*"

  @doc "A small label."
  def badge(assigns) do
    ~H"""
    <span>{@label}</span>
    """
  end
end
