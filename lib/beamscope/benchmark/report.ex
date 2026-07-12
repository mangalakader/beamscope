defmodule Beamscope.Benchmark.Report do
  @moduledoc """
  Renders one or more `Beamscope.Benchmark.Runner.run/1` results as a
  Markdown report matching `docs/search-benchmark-2026-07.md`'s table
  format, and writes it to disk with an ISO8601 timestamp in the filename
  — so re-running the benchmark never silently overwrites a previous
  result.
  """

  @doc "Renders `results` (a list of `Runner.run/1` maps) as a Markdown string."
  @spec render([map()], DateTime.t()) :: String.t()
  def render(results, generated_at \\ DateTime.utc_now()) do
    """
    # Beamscope benchmark report

    Generated #{DateTime.to_iso8601(generated_at)} by `mix beamscope.benchmark`.
    Token counts are real BPE counts (a vendored cl100k_base-equivalent
    tokenizer via the `tokenizers` Hex package — see
    `Beamscope.Benchmark.Tokenizer`), not an estimate. Baseline is a real
    grep-equivalent scan + full read of every matching file.

    #{Enum.map_join(results, "\n", &render_repo/1)}
    """
  end

  @doc "Writes `render/2`'s output to `<dir>/benchmark_<repo_basename>_<timestamp>.md`, one file per repo result."
  @spec write([map()], String.t()) :: [String.t()]
  def write(results, dir) do
    File.mkdir_p!(dir)
    generated_at = DateTime.utc_now()

    Enum.map(results, fn result ->
      timestamp = generated_at |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")
      basename = result.repo_path |> Path.basename() |> String.replace(~r/[^\w.-]/, "_")
      path = Path.join(dir, "benchmark_#{basename}_#{timestamp}.md")

      File.write!(path, render([result], generated_at))
      path
    end)
  end

  defp render_repo(%{repo_path: repo_path, rows: rows, timings: timings}) do
    """
    ## #{repo_path}

    #{render_table(rows)}
    #{render_timings(timings)}
    """
  end

  defp render_table([]),
    do: "_No tasks could be auto-discovered for this repo (empty or unbuildable graph)._\n"

  defp render_table(rows) do
    header = "| Task | Description | Baseline tokens | Beamscope tokens | Reduction | Quality |"
    separator = "|---|---|---:|---:|---:|---|"
    body = Enum.map_join(rows, "\n", &render_row/1)

    Enum.join([header, separator, body], "\n") <> "\n"
  end

  defp render_row(row) do
    reduction =
      case row.reduction_pct do
        nil -> "—"
        pct -> "#{Float.round(pct, 1)}%"
      end

    "| #{row.task} | #{row.description} | #{row.baseline_tokens} | #{row.beamscope_tokens} | " <>
      "#{reduction} | #{row.quality_note || "—"} |"
  end

  defp render_timings([]), do: ""

  defp render_timings(timings) do
    header =
      "\n### Latency (Benchee, real repeated runs)\n\n| Scenario | Average | Median |\n|---|---:|---:|"

    body = Enum.map_join(timings, "\n", &render_timing_row/1)

    Enum.join([header, body], "\n") <> "\n"
  end

  defp render_timing_row(%{name: name, average_us: average_us, median_us: median_us}) do
    "| #{name} | #{format_duration(average_us)} | #{format_duration(median_us)} |"
  end

  defp format_duration(microseconds) when microseconds >= 1_000_000 do
    "#{Float.round(microseconds / 1_000_000, 2)}s"
  end

  defp format_duration(microseconds) when microseconds >= 1_000 do
    "#{Float.round(microseconds / 1_000, 1)}ms"
  end

  defp format_duration(microseconds), do: "#{Float.round(microseconds, 1)}µs"
end
