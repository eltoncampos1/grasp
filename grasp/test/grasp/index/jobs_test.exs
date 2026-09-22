defmodule Grasp.Index.JobsTest do
  use ExUnit.Case, async: true

  alias Grasp.Index.Jobs

  @perform "SampleApp.Workers.Mailer.perform/1"
  @range %{start: {4, 5}, end: {4, 40}}

  test "a call to a worker's new/1 is an enqueue on its perform/1" do
    assert [call] = resolve([call("SampleApp.Workers.Mailer.new/1", :remote)])

    assert call == %{
             target: @perform,
             kind: :enqueue,
             range: @range,
             job: %{worker: "SampleApp.Workers.Mailer", queue: "mail"},
             via: %{target: "SampleApp.Workers.Mailer.new/1", kind: :remote}
           }
  end

  test "an enqueue call remembers the call it stands for" do
    assert [%{via: via}] = resolve([call("SampleApp.Workers.Mailer.new/2", :imported)])
    assert via == %{target: "SampleApp.Workers.Mailer.new/2", kind: :imported}
  end

  test "new/2 enqueues too" do
    assert [%{target: @perform, kind: :enqueue}] =
             resolve([call("SampleApp.Workers.Mailer.new/2", :remote)])
  end

  test "a worker with no queue in its meta is on the default queue" do
    entries = [%{"kind" => "oban_worker", "target" => @perform, "meta" => %{}}]
    [record] = Jobs.resolve([record([call("SampleApp.Workers.Mailer.new/1", :remote)])], entries)
    assert [%{job: %{queue: "default"}}] = record.calls
  end

  test "new/1 on a module that is not a worker is left alone" do
    call = call("SampleApp.Greeter.new/1", :remote)
    assert [^call] = resolve([call])
  end

  test "a worker's other functions are left alone" do
    call = call("SampleApp.Workers.Mailer.perform/1", :remote)
    assert [^call] = resolve([call])
  end

  test "only oban_worker entries name workers" do
    entries = [%{"kind" => "genserver", "target" => @perform, "meta" => %{}}]
    call = call("SampleApp.Workers.Mailer.new/1", :remote)
    [record] = Jobs.resolve([record([call])], entries)
    assert record.calls == [call]
  end

  test "the call keeps its place among the record's calls" do
    first = call("SampleApp.Greeter.greet/1", :remote, %{start: {2, 1}, end: {2, 6}})
    last = call("SampleApp.Greeter.greet/2", :remote, %{start: {6, 1}, end: {6, 6}})
    enqueue = call("SampleApp.Workers.Mailer.new/1", :remote)

    assert [^first, %{kind: :enqueue}, ^last] = resolve([first, enqueue, last])
  end

  test "a record without calls is unchanged" do
    record = %{id: "SampleApp.Greeter.greet/1", calls: []}
    assert [^record] = Jobs.resolve([record], entries())
  end

  defp resolve(calls) do
    [record] = Jobs.resolve([record(calls)], entries())
    record.calls
  end

  defp record(calls), do: %{id: "SampleAppWeb.GreetController.enqueue/2", calls: calls}

  defp call(target, kind, range \\ @range), do: %{target: target, kind: kind, range: range}

  defp entries do
    [
      %{
        "kind" => "route",
        "label" => "GET /greet/:name",
        "target" => "SampleAppWeb.GreetController.show/2",
        "meta" => %{"verb" => "GET", "path" => "/greet/:name"}
      },
      %{
        "kind" => "oban_worker",
        "label" => @perform,
        "target" => @perform,
        "meta" => %{"queue" => "mail", "max_attempts" => 5}
      }
    ]
  end
end
