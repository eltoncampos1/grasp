defmodule Grasp.MixProject do
  use Mix.Project

  def project do
    [
      app: :grasp,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [mod: {Grasp.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  def cli do
    [preferred_envs: [test: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:makeup, "~> 1.2"},
      {:makeup_elixir, "~> 1.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:grasp_index, path: "../grasp_index"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      "assets.build": ["esbuild grasp"],
      "assets.deploy": ["esbuild grasp --minify"]
    ]
  end
end
