defmodule Beamlens.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :beamlens,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Beamlens",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Beamlens.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:libgraph, "~> 0.16"},
      {:telemetry, "~> 1.2"},
      {:igniter, "~> 0.5", optional: true},
      {:plug, "~> 1.18"},
      {:bandit, "~> 1.5"},
      {:bumblebee, "~> 0.7", optional: true},
      {:nx, "~> 0.12", optional: true},
      {:torchx, "~> 0.12", optional: true},
      {:tokenizers, "~> 0.5"},
      {:benchee, "~> 1.3", only: [:dev, :test], optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Compiler-accurate code intelligence for BEAM codebases: chunking and " <>
      "call-graph extraction for Erlang and Elixir via :epp/Code.string_to_quoted, " <>
      "not a generic tree-sitter grammar."
  end

  defp package do
    [
      licenses: ["MIT"],
      # TODO: add a real `links: %{"GitHub" => "..."}` once this has a public repo —
      # intentionally omitted rather than guessing a URL that doesn't exist yet.
      files: ~w(lib mix.exs README.md ENGINEERING.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "ENGINEERING.md"]
    ]
  end
end
