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
      extras: ["README.md", "ENGINEERING.md"],
      before_closing_body_tag: &mermaid_script/1
    ]
  end

  # ExDoc doesn't render Mermaid code blocks itself (they'd otherwise just
  # show up as plain text on HexDocs) — this loads Mermaid.js from a CDN
  # and renders every `pre code.mermaid` block client-side once the page
  # loads. `:epub` can't run JS, so only inject it for `:html`.
  defp mermaid_script(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({ svg, bindFunctions }) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp mermaid_script(_formatter), do: ""
end
