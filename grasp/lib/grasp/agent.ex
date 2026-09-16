defmodule Grasp.Agent do
  @moduledoc """
  The review agent: the Claude Code CLI, run headless against this viewer's own MCP
  endpoint so it can read the index and arrange the cards the user is looking at.

  One conversation runs per viewer session name, under `Grasp.AgentSupervisor` and found
  through `Grasp.AgentRegistry`, so a browser reload rejoins the run it left rather than
  starting another. This module is the whole interface the page needs: everything it
  returns is the `t:view/0` the transcript renders from, and the same view arrives as
  `{:agent, name, view}` on `"agent:<name>"` after every change.
  """

  alias Grasp.Agent.Runner
  alias Grasp.Agent.Stream

  @type name :: String.t()

  @type view :: %{
          entries: [Stream.entry()],
          running?: boolean(),
          claude_session_id: String.t() | nil,
          log: [String.t()],
          last_result: String.t() | nil
        }

  @doc "Starts the conversation named `name` if it is not running."
  @spec ensure(name()) :: :ok
  def ensure(name) do
    case DynamicSupervisor.start_child(Grasp.AgentSupervisor, {Runner, name}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Subscribes the caller to `{:agent, name, view}` broadcasts."
  @spec subscribe(name()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(Grasp.PubSub, Runner.topic(name))

  @doc "The current view of the conversation."
  @spec get(name()) :: view()
  def get(name), do: GenServer.call(Runner.via(name), :get)

  @doc """
  Runs `prompt`, continuing the CLI session the previous prompt opened.

  The CLI takes one prompt per run, so this returns `{:error, :running}` while a run is
  live, and `{:error, :no_command}` when the configured agent command is not an executable
  on this machine.
  """
  @spec send_prompt(name(), String.t()) :: :ok | {:error, :running | :no_command}
  def send_prompt(name, prompt), do: GenServer.call(Runner.via(name), {:prompt, prompt})

  @doc "Ends a live run; a finished conversation is left alone."
  @spec stop(name()) :: :ok
  def stop(name), do: GenServer.call(Runner.via(name), :stop)

  @doc "Ends a live run and clears the transcript, the log and the CLI session id."
  @spec reset(name()) :: :ok
  def reset(name), do: GenServer.call(Runner.via(name), :reset)
end
