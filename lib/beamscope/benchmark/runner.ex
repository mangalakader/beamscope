defmodule Beamscope.Benchmark.Runner do
  @moduledoc """
  Orchestrates one repo's benchmark: auto-discovers representative tasks
  (`Beamscope.Benchmark.TaskDiscovery`), measures the real "no beamscope"
  baseline (`Beamscope.Benchmark.Baseline`) against the real beamscope
  `Beamscope.Repo` output for each, counts real tokens
  (`Beamscope.Benchmark.Tokenizer`), and times both with `Benchee` for a
  repeatable latency comparison — the same methodology used for
  `docs/search-benchmark-2026-07.md`'s manual benchmark, automated so it
  can be run again and again against any repo.
  """

  alias Beamscope.Benchmark.{Baseline, TaskDiscovery, Tokenizer}
  alias Beamscope.Callgraph.Store, as: CallgraphStore
  alias Beamscope.Repo

  @spec run(String.t()) :: %{repo_path: String.t(), rows: [map()], timings: [map()]}
  def run(repo_path) do
    graph = CallgraphStore.get_or_build(repo_path)
    tasks = TaskDiscovery.pick_tasks(graph)

    rows =
      [
        get_callers_row(repo_path, tasks.get_callers),
        get_callees_row(repo_path, tasks.get_callees),
        find_call_path_row(repo_path, tasks.find_call_path),
        search_code_exact_row(repo_path, tasks.search_code),
        search_code_conceptual_row(repo_path, tasks.search_code)
      ]
      |> Enum.reject(&is_nil/1)

    %{repo_path: repo_path, rows: rows, timings: time_rows(repo_path, tasks)}
  end

  defp get_callers_row(_repo_path, nil), do: nil

  defp get_callers_row(repo_path, %{module: module, function: function, qualified_name: qn}) do
    {:ok, result} = Repo.callers(repo_path, module, function)
    baseline = Baseline.measure(repo_path, [function])
    beamscope = measure_beamscope(result)

    row("get_callers", "#{qn} (#{length(result.callers)} callers)", baseline, beamscope, nil)
  end

  defp get_callees_row(_repo_path, nil), do: nil

  defp get_callees_row(repo_path, %{module: module, function: function, qualified_name: qn}) do
    {:ok, result} = Repo.callees(repo_path, module, function)
    baseline = Baseline.measure(repo_path, [function])
    beamscope = measure_beamscope(result)

    row("get_callees", "#{qn} (#{length(result.callees)} callees)", baseline, beamscope, nil)
  end

  defp find_call_path_row(_repo_path, nil), do: nil

  defp find_call_path_row(repo_path, %{from: from, to: to}) do
    {:ok, result} = Repo.call_path(repo_path, from.module, from.function, to.module, to.function)
    baseline = Baseline.measure(repo_path, [from.function, to.function])
    beamscope = measure_beamscope(result)

    quality =
      if result.path, do: "path found (#{length(result.path)} nodes)", else: "no path found"

    row(
      "find_call_path",
      "#{from.qualified_name} -> #{to.qualified_name}",
      baseline,
      beamscope,
      quality
    )
  end

  defp search_code_exact_row(_repo_path, %{exact_name_query: nil}), do: nil

  defp search_code_exact_row(repo_path, %{exact_name_query: query, exact_name_term: term}) do
    {:ok, result} = Repo.search(repo_path, query, limit: 5)
    baseline = Baseline.measure(repo_path, [term])
    beamscope = measure_beamscope(result)

    quality =
      if Enum.any?(result.exact_matches, &(&1.match_kind == :definition)) do
        "PASS — a real definition found in exact_matches"
      else
        "no definition found in exact_matches — inspect manually"
      end

    row("search_code (exact-name)", query, baseline, beamscope, quality)
  end

  defp search_code_conceptual_row(repo_path, %{conceptual_query: query}) do
    {:ok, result} = Repo.search(repo_path, query, limit: 5)
    baseline = Baseline.measure(repo_path, [])
    beamscope = measure_beamscope(result)

    row(
      "search_code (conceptual)",
      query,
      baseline,
      beamscope,
      "no auto quality check — review semantic_matches manually"
    )
  end

  defp measure_beamscope(data) do
    json = Jason.encode!(data)
    %{bytes: byte_size(json), tokens: Tokenizer.count(json)}
  end

  defp row(task, description, baseline, beamscope, quality_note) do
    baseline_tokens = Tokenizer.count(baseline.text)

    reduction =
      if baseline_tokens > 0, do: 100 * (1 - beamscope.tokens / baseline_tokens), else: nil

    quality_note =
      if baseline.capped? do
        capped_note =
          "baseline capped — term matched most of the repo, real reduction is even larger"

        if quality_note, do: "#{quality_note}; #{capped_note}", else: capped_note
      else
        quality_note
      end

    %{
      task: task,
      description: description,
      baseline_bytes: baseline.bytes,
      baseline_tokens: baseline_tokens,
      beamscope_bytes: beamscope.bytes,
      beamscope_tokens: beamscope.tokens,
      reduction_pct: reduction,
      quality_note: quality_note
    }
  end

  # A real, repeatable wall-clock comparison via Benchee — a separate
  # dimension from the token-count rows above (see
  # docs/search-benchmark-2026-07.md's "Efficiency: token-cheap is not the
  # same as latency-cheap"). Short time/warmup by default so a benchmark
  # run stays quick to re-run "again and again"; only covers get_callers/
  # get_callees, the two shapes where the baseline side (grep+read) is
  # itself deterministic and cheap enough to repeat many times.
  defp time_rows(repo_path, tasks) do
    scenarios =
      %{}
      |> maybe_put_scenarios("get_callers", repo_path, tasks.get_callers, &Repo.callers/3)
      |> maybe_put_scenarios("get_callees", repo_path, tasks.get_callees, &Repo.callees/3)

    cond do
      scenarios == %{} ->
        []

      not Code.ensure_loaded?(Benchee) ->
        []

      true ->
        # `apply/3` rather than a literal `Benchee.run/2` call: Benchee is
        # `only: [:dev, :test]` in mix.exs, which never propagates to a
        # consuming project's own deps — a static call would warn "module
        # not available" at compile time for every consumer, in every env.
        suite = apply(Benchee, :run, [scenarios, [time: 1, warmup: 0.5]])

        Enum.map(suite.scenarios, fn scenario ->
          %{
            name: scenario.name,
            average_us: scenario.run_time_data.statistics.average / 1000,
            median_us: scenario.run_time_data.statistics.median / 1000
          }
        end)
    end
  end

  defp maybe_put_scenarios(scenarios, _label, _repo_path, nil, _repo_fun), do: scenarios

  defp maybe_put_scenarios(
         scenarios,
         label,
         repo_path,
         %{module: module, function: function},
         repo_fun
       ) do
    scenarios
    |> Map.put("#{label} (beamscope)", fn -> repo_fun.(repo_path, module, function) end)
    |> Map.put("#{label} (baseline grep+read)", fn -> Baseline.measure(repo_path, [function]) end)
  end
end
