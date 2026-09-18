defmodule SampleApp.Counter do
  @moduledoc "A GenServer defining two callbacks; the rest are use GenServer defaults."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, 0, opts)

  @impl true
  def init(count), do: {:ok, count}

  @impl true
  def handle_call(:next, _from, count), do: {:reply, count + 1, count + 1}
end
