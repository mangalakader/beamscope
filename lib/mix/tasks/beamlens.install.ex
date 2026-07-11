if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Beamlens.Install do
    @moduledoc """
    Installer for `beamlens`, invoked via `mix igniter.install beamlens`.

    `igniter.install` already adds `beamlens` to `mix.exs` before this task
    runs, so there's nothing left to scaffold yet — no MCP server config, no
    Qdrant/Ollama settings — because those features don't exist yet. This
    task's only job right now is to print an accurate status notice so
    nobody assumes more is wired up than actually is.
    """

    @shortdoc "Installs beamlens (chunking + call-graph extraction only, no MCP/search yet)"

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{}
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Igniter.add_notice(igniter, """
      beamlens added. What works right now:

        Beamlens.Chunking.Pipeline.chunk_repo/2
        Beamlens.Callgraph.Pipeline.extract_repo/2
        Beamlens.Callgraph.Graph.callers/2, callees/2, shortest_path/3

      Not built yet: MCP server tools, semantic/embedding search (search_code),
      incremental indexing. See the beamlens README for current status.
      """)
    end
  end
else
  defmodule Mix.Tasks.Beamlens.Install do
    @shortdoc "Installs beamlens. Requires igniter to be run."

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'beamlens.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
