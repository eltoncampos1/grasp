defmodule SampleAppWeb.ApiRouter do
  @moduledoc "A router reached through a forward, so its routes carry the mount prefix."
  use Phoenix.Router

  scope "/", SampleAppWeb do
    post("/echo", GreetController, :create)
  end
end
