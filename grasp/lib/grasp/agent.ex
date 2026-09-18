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
          last_result: String.t() | nil,
          model: String.t() | nil,
          mode: String.t()
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

  `:mcp_url` is the URL the CLI connects its `grasp` MCP server to. It is the caller's to
  give because Grasp answers under whatever prefix its host mounted it at, on the host's own
  port; without it the run is pointed at the standalone viewer.
  """
  @spec send_prompt(name(), String.t(), keyword()) :: :ok | {:error, :running | :no_command}
  def send_prompt(name, prompt, opts \\ []),
    do: GenServer.call(Runner.via(name), {:prompt, prompt, opts})

  @doc "Ends a live run; a finished conversation is left alone."
  @spec stop(name()) :: :ok
  def stop(name), do: GenServer.call(Runner.via(name), :stop)

  @models ~w(haiku sonnet opus fable)
  @modes ~w(read edit)

  @doc "The model aliases the chat panel offers, cheapest first."
  @spec models() :: [String.t()]
  def models, do: @models

  @doc """
  Picks the model the next run passes to the CLI; nil returns to the configured default
  (`:agent_model`, or the CLI's own default). Applies to the next prompt, so a conversation
  can continue on a cheaper model after an expensive one mapped the ground.
  """
  @spec set_model(name(), String.t() | nil) :: :ok | {:error, :unknown_model}
  def set_model(name, nil), do: GenServer.call(Runner.via(name), {:set_model, nil})

  def set_model(name, model) when model in @models,
    do: GenServer.call(Runner.via(name), {:set_model, model})

  def set_model(_name, _model), do: {:error, :unknown_model}

  @doc "The modes the chat panel offers: reading only, or reading and editing."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc """
  Picks what the next run is allowed to do: `"read"` gives the agent the read tools alone,
  `"edit"` also lets it change files under the project root and run mix, so it can act on a
  review comment and rebuild the index. Applies to the next prompt, and survives `reset/1`.
  """
  @spec set_mode(name(), String.t()) :: :ok | {:error, :unknown_mode}
  def set_mode(name, mode) when mode in @modes,
    do: GenServer.call(Runner.via(name), {:set_mode, mode})

  def set_mode(_name, _mode), do: {:error, :unknown_mode}

  @doc "Ends a live run and clears the transcript, the log and the CLI session id."
  @spec reset(name()) :: :ok
  def reset(name), do: GenServer.call(Runner.via(name), :reset)

  @doc """
  Stops the conversation named `name` and forgets it; a name nothing is running under is
  already forgotten.

  A conversation belongs to the session it was held in, so deleting that session ends this
  too: a session opened under the same name later is a new one, and rejoining the transcript
  of the session it replaced would have the agent answer questions nobody in this session
  asked. A live run is killed with it, as `stop/1` kills one.
  """
  @spec forget(name()) :: :ok
  def forget(name) do
    GenServer.stop(Runner.via(name))
  catch
    :exit, _not_running -> :ok
  end
end
