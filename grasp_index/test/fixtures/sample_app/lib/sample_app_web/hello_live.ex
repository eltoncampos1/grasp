defmodule SampleAppWeb.HelloLive do
  @moduledoc "A LiveView with three callbacks."
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, name: "world")}

  def handle_event("rename", %{"name" => name}, socket),
    do: {:noreply, assign(socket, name: name)}

  def render(assigns) do
    ~H"""
    <p>{SampleApp.Greeter.greet(@name)}</p>
    """
  end
end
