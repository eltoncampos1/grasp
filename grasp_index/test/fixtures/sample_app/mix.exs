defmodule SampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :sample_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:grasp_index, path: "../../..", only: :dev, runtime: false}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
