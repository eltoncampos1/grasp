defmodule Grasp.Agent.RunnerKillTest do
  # Names the pid file through the environment the port inherits, which is process-wide, so
  # it cannot share the run with the tests that spawn the same fake CLI.
  use ExUnit.Case, async: false

  alias Grasp.Agent.Runner

  @deadline_ms 1_000

  setup do
    name = "t-#{System.unique_integer([:positive])}"
    pid_file = Path.join(System.tmp_dir!(), "#{name}.pid")
    System.put_env("FAKE_CLAUDE_PID_FILE", pid_file)

    on_exit(fn ->
      System.delete_env("FAKE_CLAUDE_PID_FILE")
      File.rm(pid_file)
    end)

    :ok = Grasp.Agent.ensure(name)
    :ok = Grasp.Agent.subscribe(name)
    %{name: name, pid_file: pid_file}
  end

  test "stop/1 kills the CLI process", %{name: name, pid_file: pid_file} do
    :ok = Grasp.Agent.send_prompt(name, "HANG one")
    os_pid = await_pid(pid_file)

    assert :ok = Grasp.Agent.stop(name)
    assert_receive {:agent, ^name, %{running?: false}}, @deadline_ms
    assert await_exit(os_pid), "the CLI process #{os_pid} outlived the run"
  end

  test "a runner that goes away takes its CLI with it", %{name: name, pid_file: pid_file} do
    :ok = Grasp.Agent.send_prompt(name, "HANG one")
    os_pid = await_pid(pid_file)

    :ok = GenServer.stop(Runner.via(name))
    assert await_exit(os_pid), "the CLI process #{os_pid} outlived its runner"
  end

  defp await_pid(pid_file) do
    poll(fn ->
      case File.read(pid_file) do
        {:ok, contents} -> Integer.parse(String.trim(contents))
        {:error, _reason} -> :error
      end
    end) || flunk("the fake CLI never recorded its pid")
  end

  # `kill -0` fails once the pid is gone; the Erlang VM reaps the child, so there is no
  # zombie left holding the pid alive.
  defp await_exit(os_pid) do
    poll(fn ->
      {_output, status} =
        System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

      status != 0
    end)
  end

  defp poll(fun, waited \\ 0)
  defp poll(_fun, waited) when waited >= @deadline_ms, do: nil

  defp poll(fun, waited) do
    case fun.() do
      {value, _rest} ->
        value

      true ->
        true

      _not_yet ->
        Process.sleep(10)
        poll(fun, waited + 10)
    end
  end
end
