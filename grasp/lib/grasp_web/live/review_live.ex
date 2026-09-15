defmodule GraspWeb.ReviewLive do
  @moduledoc "The review page: sidebar, card canvas and palette. Filled in by later tasks."

  use GraspWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app">
      <h1 class="brand">Grasp</h1>
    </main>
    """
  end
end
