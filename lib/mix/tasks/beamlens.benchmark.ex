defmodule Mix.Tasks.Beamlens.Benchmark do
  @moduledoc """
  Benchmarks beamlens against a real grep/read baseline, for one or more
  repos of your choice — self-serve, repeatable, no external Python/tiktoken
  dependency.

      mix beamlens.benchmark --repo /path/to/repo
      mix beamlens.benchmark --repo /path/to/repo1 --repo /path/to/repo2
      mix beamlens.benchmark --repo /path/to/repo --output docs/benchmarks/

  For each `--repo`, auto-discovers representative `get_callers`/
  `get_callees`/`find_call_path`/`search_code` tasks from the repo's own
  call graph (see `Beamlens.Benchmark.TaskDiscovery` — no hardcoded
  per-repo function names, works against any repo), measures real token
  counts for both the baseline and beamlens (`Beamlens.Benchmark.Tokenizer`
  — a vendored cl100k_base-equivalent tokenizer via the `tokenizers` Hex
  package, cross-checked against real `tiktoken` — no Python venv), and
  times both with `Benchee` for a real, repeatable latency comparison.

  Writes one timestamped Markdown report per repo to `--output` (default
  `docs/benchmarks/`) as `benchmark_<repo_name>_<timestamp>.md` — re-running
  never silently overwrites a previous result, so you can track how numbers
  change over time.
  """

  @shortdoc "Benchmarks beamlens vs. a real grep/read baseline against repos of your choice"

  use Mix.Task

  alias Beamlens.Benchmark.{Report, Runner}

  @default_output "docs/benchmarks/"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [repo: [:string, :keep], output: :string])
    repos = Keyword.get_values(opts, :repo)
    output = Keyword.get(opts, :output, @default_output)

    if repos == [] do
      Mix.raise("pass at least one --repo /path/to/repo")
    end

    Mix.Task.run("app.start")

    results =
      Enum.map(repos, fn repo_path ->
        Mix.shell().info("Benchmarking #{repo_path}...")
        Runner.run(repo_path)
      end)

    paths = Report.write(results, output)

    Enum.each(paths, &Mix.shell().info("Wrote #{&1}"))
  end
end
