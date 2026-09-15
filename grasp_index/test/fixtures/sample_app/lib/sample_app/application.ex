defmodule SampleApp.Application do
  @moduledoc "Application module (not started by the fixture)."
  use Application

  @impl true
  def start(_type, _args), do: Supervisor.start_link([SampleApp.Counter], strategy: :one_for_one)
end
