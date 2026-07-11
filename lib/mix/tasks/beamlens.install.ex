if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Beamlens.Install do
    @moduledoc """
    Installer for `beamlens`, invoked via `mix igniter.install beamlens`.

    `igniter.install` already adds `beamlens` to `mix.exs` before this task
    runs, so there's nothing left to scaffold yet — no config needed to run
    the MCP server. This task's only job right now is to print an accurate
    status notice so nobody assumes more is wired up than actually is.
    """

    @shortdoc "Installs beamlens (chunking, call-graph, MCP server; no incremental indexing yet)"

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{}
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Igniter.add_notice(igniter, """
      beamlens added. What works right now:

        mix beamlens.mcp                          # MCP server: get_callers, get_callees,
                                                    # find_call_path, search_code
        Beamlens.Repo.callers/3, callees/3, call_path/5, search/3
        Beamlens.Chunking.Pipeline.chunk_repo/2
        Beamlens.Callgraph.Pipeline.extract_repo/2

      search_code needs the optional bumblebee/nx/torchx deps — see the
      README's "Setup" section.

      Not built yet: incremental indexing (every index build re-processes
      the whole file set). See the beamlens README for current status.
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
