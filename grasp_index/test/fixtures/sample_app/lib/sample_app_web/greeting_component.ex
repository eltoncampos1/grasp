defmodule SampleAppWeb.GreetingComponent do
  @moduledoc "A LiveComponent; `use Phoenix.LiveComponent` also injects `__live__/0`."
  use Phoenix.LiveComponent

  def handle_event("shout", _params, socket), do: {:noreply, assign(socket, loud: true)}

  def render(assigns) do
    ~H"""
    <span>{SampleApp.Greeter.greet(@name)}</span>
    """
  end
end
