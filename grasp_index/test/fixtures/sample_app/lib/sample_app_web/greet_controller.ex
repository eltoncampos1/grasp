defmodule SampleAppWeb.GreetController do
  @moduledoc "Controller actions that call into the greeter."
  use Phoenix.Controller, formats: [:html]

  @doc "Greets the named person."
  def show(conn, %{"name" => name}) do
    render(conn, :show, name: SampleApp.Greeter.greet(name))
  end

  @doc "Greets loudly."
  def create(conn, %{"name" => name}), do: text(conn, SampleApp.Greeter.greet(name, true))
end
