defmodule SampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:grasp, path: "../../..", only: :dev, runtime: false},
        {:phoenix, "~> 1.8"},
        {:phoenix_live_view, "~> 1.2"},
        {:oban, "~> 2.19"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
