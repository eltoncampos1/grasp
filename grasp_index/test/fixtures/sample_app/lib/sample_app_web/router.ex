defmodule SampleAppWeb.Router do
  @moduledoc "Routes exercised by the entry-point detector."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/", SampleAppWeb do
    pipe_through(:browser)
    get("/greet/:name", GreetController, :show)
    post("/greet", GreetController, :create)
    live("/hello", HelloLive)
  end
end
