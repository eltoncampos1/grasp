defmodule Grasp.Agent.Runner do
  @moduledoc """
  One agent conversation: a named GenServer that runs the Claude Code CLI as a port and
  folds its output into a transcript.

  The CLI is spawned with `{:spawn_executable, _}` rather than through a shell, so the
  prompt and the inline MCP config reach it as argv and never go near shell quoting. The
  port is opened in `{:line, _}` mode: the CLI writes one JSON object per line, so a line
  is exactly one event, and the rare line longer than the limit arrives as `:noeol` chunks
  that are buffered until its `:eol` completes it.

  `:stderr_to_stdout` merges the CLI's error output into the same stream. The two cannot be
  read separately from one port, and a run that fails usually says why on stderr — as a
  non-JSON line, which `Grasp.Agent.Stream` keeps in `log` for the page to show. The cost
  is that a stderr line can interleave between two JSON lines; line mode keeps each of them
  whole regardless.

  Closing the port does not stop the CLI: the port's process keeps running with its stdin
  closed, and a real run would only notice at its next write — a whole model call away, with
  tokens being spent all the while. Every path that ends a run therefore sends the OS
  process a SIGTERM first and closes the port after; a CLI that chooses to ignore SIGTERM
  is past what this can do. The runner traps exits so that path also covers
  its own death: a runner that is stopped, supervised down or crashes takes its CLI with it
  rather than leaving one reparented to init.

  A run outlives its subscribers, so state lives here rather than in the LiveView. Every
  change broadcasts `{:agent, name, view}` on `"agent:<name>"`.
  """

  use GenServer

  alias Grasp.Agent.Command
  alias Grasp.Agent.Stream

  @type name :: Grasp.Agent.name()

  @doc false
  def child_spec(name),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [name]}, restart: :transient}

  @doc false
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: via(name))

  @doc false
  @spec via(name()) :: GenServer.name()
  def via(name), do: {:via, Registry, {Grasp.AgentRegistry, name}}

  @doc false
  @spec topic(name()) :: String.t()
  def topic(name), do: "agent:" <> name

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)
    {:ok, %{name: name, stream: Stream.new(), port: nil, buffer: "", running?: false}}
  end

  @impl true
  def terminate(_reason, state), do: halt(state, nil)

  @impl true
  def handle_call(:get, _from, state), do: {:reply, view(state), state}

  def handle_call({:prompt, _prompt}, _from, %{running?: true} = state),
    do: {:reply, {:error, :running}, state}

  def handle_call({:prompt, prompt}, _from, state) do
    {command, argv} =
      Command.build(prompt,
        command: Application.fetch_env!(:grasp, :agent_command),
        session: state.name,
        mcp_url: Command.mcp_url(),
        resume: state.stream.claude_session_id,
        model: Application.get_env(:grasp, :agent_model)
      )

    case executable(command) do
      nil ->
        {:reply, {:error, :no_command}, state}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 1_048_576},
            {:args, argv},
            {:cd, Command.cwd()}
          ])

        stream = Stream.prompt(state.stream, prompt)

        {:reply, :ok,
         broadcast(%{state | stream: stream, port: port, buffer: "", running?: true})}
    end
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, broadcast(halt(state, "stopped"))}

  def handle_call(:reset, _from, state) do
    state = halt(state, nil)
    {:reply, :ok, broadcast(%{state | stream: Stream.new()})}
  end

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    stream = Stream.apply(state.stream, state.buffer <> chunk)
    {:noreply, broadcast(%{state | stream: stream, buffer: ""})}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    stream = Stream.apply(state.stream, state.buffer)

    stream =
      if code != 0 and not stream.done? do
        Stream.error(stream, "claude exited with status #{code}")
      else
        stream
      end

    {:noreply, broadcast(%{state | stream: stream, port: nil, buffer: "", running?: false})}
  end

  # Trapping exits turns a linked process's death into a message; only a port's is routine.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # A port that was closed by `stop/1` can still have output or its exit status in flight.
  def handle_info({port, _payload}, state) when is_port(port), do: {:noreply, state}

  defp halt(%{port: nil} = state, _reason), do: state

  defp halt(state, reason) do
    kill(Port.info(state.port, :os_pid))

    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    stream = if reason, do: Stream.error(state.stream, reason), else: state.stream
    %{state | stream: stream, port: nil, buffer: "", running?: false}
  end

  defp kill({:os_pid, pid}), do: System.cmd("kill", ["-TERM", Integer.to_string(pid)])
  defp kill(_info), do: :ok

  # `System.find_executable/1` resolves a bare name on PATH and an absolute or relative
  # path, and answers nil unless the result is executable — so a file the user forgot to
  # `chmod +x` is reported as a missing command instead of raising :eacces in `Port.open/2`.
  defp executable(command), do: System.find_executable(command)

  defp view(state) do
    %{
      entries: state.stream.entries,
      running?: state.running?,
      claude_session_id: state.stream.claude_session_id,
      log: state.stream.log,
      last_result: state.stream.result_text
    }
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Grasp.PubSub, topic(state.name), {:agent, state.name, view(state)})
    state
  end
end
