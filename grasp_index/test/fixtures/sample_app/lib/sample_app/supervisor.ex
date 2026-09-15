defmodule SampleApp.Supervisor do
  @moduledoc "A supervisor whose init/1 is written by hand (not started by the fixture)."
  use Supervisor

  @doc "Starts the supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, :ok, opts)

  @impl true
  def init(:ok), do: Supervisor.init([], strategy: :one_for_one)
end
