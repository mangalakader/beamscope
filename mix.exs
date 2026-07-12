defmodule Beamscope.MixProject do
  use Mix.Project

  @version "0.1.1"

  def project do
    [
      app: :beamscope,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Beamscope",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Beamscope.Application, []}
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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
      links: %{"GitHub" => "https://github.com/mangalakader/beamscope"},
      files: ~w(lib priv/tokenizer mix.exs README.md ENGINEERING.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/mangalakader/beamscope",
      source_ref: "v#{@version}",
      extras: ["README.md", "ENGINEERING.md"]
    ]
  end
end
