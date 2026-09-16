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
    # Every route sits behind `GraspWeb.Plugs.LocalOnly`, and ConnTest's default host is not
    # a loopback name.
    {:ok, conn: %{Phoenix.ConnTest.build_conn() | host: "127.0.0.1"}}
  end
end
