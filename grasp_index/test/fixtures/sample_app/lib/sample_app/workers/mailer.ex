defmodule SampleApp.Workers.Mailer do
  @moduledoc "An Oban worker."
  use Oban.Worker, queue: :mail, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"name" => name}}), do: {:ok, SampleApp.Greeter.greet(name)}
end
