defmodule Grasp.Index.Viewer do
  @moduledoc """
  Locates a checkout of the Grasp repository and works out what has to happen before the
  viewer can serve an index from it.

  The viewer is a Phoenix application and is never a dependency of the project under
  review — its Phoenix, LiveView, Bandit and MCP pins would have to agree with that
  project's own. It runs from its own checkout instead, as a separate Mix project with a
  separate build, and `mix grasp.serve` reaches it through this module: `checkout/1` says
  which directory holds it, `project/1` finds the viewer's Mix project inside that
  directory, `steps/3` lists the commands that directory still needs, and `run/2` carries
  them out.

  Every command goes through a `t:runner/0`, a function of an argv and a directory
  returning an exit status. `shell/2` is the one that runs real commands; a caller that
  wants to see what would happen without doing it passes its own. Nothing here inspects a
  command's output: the exit status alone decides whether the run continues, so a step
  that fails stops the run with the command that failed named in the error.
  """

  @type runner :: ([String.t()], Path.t() -> non_neg_integer())

  @type step ::
          {:clone, url :: String.t(), into :: Path.t()}
          | {:deps, project :: Path.t()}
          | {:assets, project :: Path.t()}
          | {:serve, project :: Path.t(), argv :: [String.t()]}

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

  The result is always expanded, so a caller may hand it straight to a command's `cd`.
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

    Path.expand(path)
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
  at `grasp/` under it, the layout a clone of this repository has. An existing directory
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

  A step whose status is not 0 ends the run with the command that failed and the status it
  returned, so the caller reports the failing command rather than the last one in the list.
  """
  @spec run([step()], runner()) :: :ok | {:error, String.t()}
  def run(steps, runner) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      {argv, dir} = command(step)

      case runner.(argv, dir) do
        0 -> {:cont, :ok}
        status -> {:halt, {:error, "#{Enum.join(argv, " ")} failed with status #{status}"}}
      end
    end)
  end

  @doc """
  Runs a command, streaming its output to this process' own.

  The child shares the terminal's process group, so Ctrl-C reaches it as well as the
  launcher and stopping the launcher stops the viewer with it. An executable that is not
  on `PATH` is reported by name and answered with 127, the status a shell gives a command
  it cannot find, so the run stops on a missing `git` or `mix` saying which one is missing.
  """
  @spec shell([String.t()], Path.t()) :: non_neg_integer()
  def shell([exe | args], dir) do
    if System.find_executable(exe) do
      {_stream, status} =
        System.cmd(exe, args,
          cd: dir,
          into: IO.stream(),
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "dev"}]
        )

      status
    else
      IO.puts("#{exe}: not found")
      127
    end
  end

  # A clone runs in the parent of the directory it creates, which git will not create itself.
  defp command({:clone, url, into}) do
    parent = Path.dirname(into)
    File.mkdir_p!(parent)
    {["git", "clone", url, into], parent}
  end

  defp command({:deps, project}), do: {["mix", "deps.get"], project}
  defp command({:assets, project}), do: {["mix", "assets.build"], project}
  defp command({:serve, project, argv}), do: {["mix", "grasp.viewer" | argv], project}
end
