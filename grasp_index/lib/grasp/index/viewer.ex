defmodule Grasp.Index.Viewer do
  @moduledoc """
  Locates a checkout of the Grasp repository and works out what has to happen before the
  viewer can serve an index from it.

  The viewer is a Phoenix application and is never a dependency of the project under
  review — its Phoenix, LiveView, Bandit and MCP pins would have to agree with that
  project's own. It runs from its own checkout instead, as a separate Mix project with a
  separate build, and `mix grasp.serve` reaches it through this module: `checkout/1` says
  which directory holds it, `project/1` finds the viewer's Mix project inside that
  directory, `steps/3` lists the commands that directory still needs, and `run/3` carries
  them out.

  Every command goes through a `t:runner/0`, a function of an argv and a directory
  returning an exit status. `shell/2` is the one that runs real commands; a caller that
  wants to see what would happen without doing it passes its own, and nothing outside the
  runner touches the filesystem — `git clone` creates the checkout and the directories
  leading to it, so the command runs in the nearest directory that already exists.

  Nothing here inspects a command's output: the exit status alone decides whether the run
  continues, so a step that fails stops the run with the command that failed named in the
  error. The plan is drawn up before the clone has happened, so the directory it guesses
  the viewer's project will be at is checked against what the clone actually produced, and
  a directory holding no `mix.exs` ends the run rather than being handed to `cd`.
  """

  @type runner :: ([String.t()], Path.t() -> non_neg_integer())

  @type step ::
          {:clone, url :: String.t(), into :: Path.t()}
          | {:deps, project :: Path.t()}
          | {:assets, project :: Path.t()}
          | {:serve, project :: Path.t(), argv :: [String.t()]}

  # Waits on the command and on the standard input it inherited from this VM at once: the
  # command exiting ends the shell with its status, and the pipe closing — which is this VM
  # gone — ends the command. `wait -n` would say this in a line, and is not in POSIX sh.
  # The pipe is read through a duplicate of it, since a shell hands a backgrounded list
  # /dev/null for its standard input and the watch would see that as the VM being gone.
  @watchdog """
  exec 3<&0
  "$@" &
  command=$!
  ( while IFS= read -r _ <&3; do :; done; kill -TERM "$command" 2>/dev/null ) &
  watch=$!
  wait "$command"
  status=$?
  kill -TERM "$watch" 2>/dev/null
  exit "$status"
  """

  @default_repo "https://github.com/gfrancischelli/grasp.git"
  @default_checkout "~/.grasp/viewer"

  @doc """
  The repository a missing checkout is cloned from.
  """
  @spec default_repo() :: String.t()
  def default_repo, do: @default_repo

  @doc """
  The directory holding the viewer's checkout.

  `:cwd_app` is the app name of the Mix project the launcher was invoked from. When that
  project is the viewer itself, the checkout is `:cwd` — someone working on Grasp serves
  the code in front of them rather than a copy of it somewhere else. Otherwise the
  checkout is `:viewer`, else `GRASP_VIEWER` in `:env`, else `#{@default_checkout}`.

  A relative path is taken as relative to `:cwd`, which is where the person typed it, and
  the result is always absolute, so a caller may hand it straight to a command's `cd`.
  """
  @spec checkout(keyword()) :: Path.t()
  def checkout(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    env = Keyword.get(opts, :env, %{})

    path =
      if Keyword.get(opts, :cwd_app) == :grasp do
        cwd
      else
        opts[:viewer] || env["GRASP_VIEWER"] || @default_checkout
      end

    Path.expand(path, cwd)
  end

  @doc """
  The viewer's Mix project inside `checkout`.

  A checkout of this repository holds the viewer under `grasp/`, beside the indexer; a
  directory that is itself the viewer's Mix project is taken as given, so a checkout
  arranged either way serves.
  """
  @spec project(Path.t()) :: Path.t()
  def project(checkout) do
    nested = Path.join(checkout, "grasp")

    if File.regular?(Path.join(nested, "mix.exs")), do: nested, else: checkout
  end

  @doc """
  The steps that bring `checkout` to a running viewer serving `argv`.

  A directory that does not exist is cloned from `repo`, and the viewer is then expected
  at `grasp/` under it, the layout a clone of this repository has; `run/3` asks the clone
  itself where the project landed rather than trusting that guess. An existing directory
  is asked where its project is. A project with no `deps/` fetches its dependencies and
  one with no built `priv/static/assets/app.js` builds its assets, so the wait falls on
  the first run and not on every one. Serving is always the last step.
  """
  @spec steps(Path.t(), String.t(), [String.t()]) :: [step()]
  def steps(checkout, repo, argv) do
    fresh? = not File.dir?(checkout)
    project = if fresh?, do: Path.join(checkout, "grasp"), else: project(checkout)

    clone = if fresh?, do: [{:clone, repo, checkout}], else: []
    deps = if File.dir?(Path.join(project, "deps")), do: [], else: [{:deps, project}]

    assets =
      if File.regular?(Path.join(project, "priv/static/assets/app.js")),
        do: [],
        else: [{:assets, project}]

    clone ++ deps ++ assets ++ [{:serve, project, argv}]
  end

  @doc """
  Runs `steps` in order through `runner`, stopping at the first one that fails.

  `on_step` is called with each step as it is about to run, which is where a caller says
  what is happening; it sees the step as it will actually run, so a project the clone put
  somewhere other than where the plan guessed is the one it reports. A step whose status
  is not 0 ends the run with the command that failed and the status it returned, so the
  caller reports the failing command rather than the last one in the list.
  """
  @spec run([step()], runner(), (step() -> any())) :: :ok | {:error, String.t()}
  def run(steps, runner, on_step \\ fn _step -> :ok end), do: walk(steps, runner, on_step, nil)

  @doc """
  Runs a command, streaming its output to this process' own.

  The child runs in its own process group, so a terminal interrupt reaches this VM and not
  the command it started — left alone, the viewer would keep serving with nothing left to
  stop it. Two things make sure it goes: SIGTERM is trapped for as long as the child runs
  and signals the child's whole process group before stopping this VM, and the child is
  started under a shell that watches the standard input it inherits from this VM. That pipe
  closes the moment this VM is gone, however it went — a trapped signal, a break the runtime
  answered by aborting, a crash — and the shell kills the command it started. The traps are
  removed once the child exits on its own.

  An executable that is not on `PATH` is reported by name and answered with 127, the
  status a shell gives a command it cannot find, so the run stops on a missing `git` or
  `mix` saying which one is missing.
  """
  @spec shell([String.t()], Path.t()) :: non_neg_integer()
  def shell([exe | args], dir) do
    case System.find_executable(exe) do
      nil ->
        Mix.shell().error("#{exe}: not found")
        127

      executable ->
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :use_stdio,
            args: ["-c", @watchdog, "sh", executable | args],
            cd: dir,
            env: [{~c"MIX_ENV", ~c"dev"}]
          ])

        traps = trap(os_pid(port))

        try do
          stream(port)
        after
          Enum.each(traps, fn {signal, id} -> System.untrap_signal(signal, id) end)
        end
    end
  end

  defp walk([], _runner, _on_step, _cloned), do: :ok

  defp walk([step | rest], runner, on_step, cloned) do
    step = in_project(step, cloned)

    with :ok <- usable(step) do
      on_step.(step)
      {argv, dir} = command(step)

      case runner.(argv, dir) do
        0 -> walk(rest, runner, on_step, cloned(step, cloned))
        status -> {:error, "#{Enum.join(argv, " ")} failed with status #{status}"}
      end
    end
  end

  # The plan named the project a clone was expected to produce; the clone that ran is what
  # says where it is.
  defp in_project({:clone, _url, _into} = step, _cloned), do: step
  defp in_project(step, nil), do: step
  defp in_project({:serve, _project, argv}, cloned), do: {:serve, cloned, argv}
  defp in_project({kind, _project}, cloned), do: {kind, cloned}

  defp cloned({:clone, _url, into}, _cloned), do: project(into)
  defp cloned(_step, cloned), do: cloned

  defp usable({:clone, _url, _into}), do: :ok
  defp usable({:serve, project, _argv}), do: mix_project(project)
  defp usable({_kind, project}), do: mix_project(project)

  defp mix_project(project) do
    if File.regular?(Path.join(project, "mix.exs")),
      do: :ok,
      else: {:error, "#{project} is not a Grasp checkout (no mix.exs)"}
  end

  # git creates the checkout and the directories leading to it, so the clone only needs a
  # directory to be run from: the nearest one above the checkout that already exists.
  defp command({:clone, url, into}),
    do: {["git", "clone", "--progress", url, into], existing(Path.dirname(into))}

  defp command({:deps, project}), do: {["mix", "deps.get"], project}
  defp command({:assets, project}), do: {["mix", "assets.build"], project}
  defp command({:serve, project, argv}), do: {["mix", "grasp.viewer" | argv], project}

  defp existing(dir) do
    parent = Path.dirname(dir)

    cond do
      File.dir?(dir) -> dir
      parent == dir -> dir
      true -> existing(parent)
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  # SIGINT is the runtime's own: it answers with the break menu and `System.trap_signal/3`
  # refuses the signal, so SIGTERM is the one a trap can carry and the watchdog covers the
  # rest. A trapped signal replaces what the runtime would have done, so the handler is
  # what stops this VM.
  defp trap(os_pid) do
    handler = fn ->
      terminate(os_pid)
      System.stop(143)
    end

    case System.trap_signal(:sigterm, handler) do
      {:ok, id} -> [{:sigterm, id}]
      {:error, _reason} -> []
    end
  end

  defp terminate(nil), do: :ok

  defp terminate(os_pid) do
    if System.find_executable("kill") do
      # The shell and the command it started share a process group of their own, and the
      # negative pid is how both are reached.
      System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  end

  defp stream(port) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        stream(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end
end
