defmodule Grasp.Index.Jobs do
  @moduledoc """
  Turns a call that enqueues an Oban job into a call on the worker that runs it.

  `use Oban.Worker` gives a worker a `new/1` and a `new/2` that build the job changeset,
  and enqueueing reads `Worker.new(args) |> Oban.insert()`. The compiler reports that as a
  call to `Worker.new/1`, a function no source file defines, so on its own it reaches
  nothing the index holds; the work it sets in motion is `Worker.perform/1`. This pass
  redirects the call there, as a call of kind `:enqueue` carrying the worker and the queue
  it runs on, so the enqueueing function reads as a caller of the worker and the site is a
  hop the reader can follow.

  Which modules are workers is what the `oban_worker` entry points say: a call to `new/1`
  or `new/2` on any other module is left as it is. A job enqueued some other way — through
  `Oban.Job.new/2` with a `worker:` option, or a changeset built somewhere else and passed
  to `Oban.insert_all/2` — names no worker at the call site and is not followed.
  """

  alias Grasp.Index.Join

  @doc """
  Redirects every enqueueing call on `records` to the worker's `perform/1`.

  `entries` are entry points in the JSON shape the document holds them in, as
  `Grasp.Index.Builder.entry_point_json/1` writes them; only the `oban_worker` ones are
  read. A call keeps its range and its place in the record's calls.
  """
  @spec resolve([Join.function_record()], [map()]) :: [Join.function_record()]
  def resolve(records, entries) do
    workers =
      for %{"kind" => "oban_worker", "target" => target} = entry <- entries,
          [worker] <- [worker_of(target)],
          into: %{} do
        {worker, %{target: target, queue: queue(entry)}}
      end

    if workers == %{}, do: records, else: Enum.map(records, &resolve_record(&1, workers))
  end

  # "Mod.perform/1" -> ["Mod"]; anything else -> []
  defp worker_of(target) do
    case Regex.run(~r/\A(.+)\.perform\/1\z/, target) do
      [_all, worker] -> [worker]
      nil -> []
    end
  end

  defp queue(%{"meta" => %{"queue" => queue}}) when is_binary(queue), do: queue
  defp queue(_entry), do: "default"

  defp resolve_record(%{calls: calls} = record, workers) do
    %{record | calls: calls |> Enum.map(&call(&1, workers)) |> Enum.uniq()}
  end

  defp resolve_record(record, _workers), do: record

  defp call(%{target: target} = call, workers) do
    case Regex.run(~r/\A(.+)\.new\/[12]\z/, target) do
      [_all, worker] ->
        case Map.fetch(workers, worker) do
          {:ok, %{target: perform, queue: queue}} ->
            %{
              target: perform,
              kind: :enqueue,
              range: call.range,
              job: %{worker: worker, queue: queue}
            }

          :error ->
            call
        end

      nil ->
        call
    end
  end
end
