defmodule GraspWeb.ConnCase do
  @moduledoc "Test case for LiveView tests: a connection plus `Phoenix.LiveViewTest`."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint GraspWeb.Endpoint
      use GraspWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
