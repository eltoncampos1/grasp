defmodule GraspIndex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/gfrancischelli/grasp"

  def project do
    [
      app: :grasp_index,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      start_permanent: false,
      deps: deps(),
      description:
        "Indexer for Grasp: a compiler-traced call graph of an Elixir project, as JSON",
      package: package(),
      name: "Grasp Index",
      docs: [main: "readme", extras: ["README.md"], source_url: @source_url]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sourceror, "~> 1.10"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
