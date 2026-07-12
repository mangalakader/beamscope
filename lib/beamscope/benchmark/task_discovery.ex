defmodule Beamscope.Benchmark.TaskDiscovery do
  @moduledoc """
  Auto-picks representative call-graph/search tasks from a repo's built
  call graph, so `mix beamscope.benchmark` doesn't need hardcoded
  per-repo function names — the same task shapes used for
  `docs/search-benchmark-2026-07.md`'s manual benchmark
  (`get_callers`/`get_callees`/`find_call_path`/`search_code`), automated
  instead of hand-picked, so the tool works against any repo.
  """

  alias Graph, as: LibGraph

  @conceptual_query "code that validates input and returns an error if it's invalid"

  @doc """
  Picks one task of each shape from `graph`. Returns `nil` for any shape
  that couldn't be auto-discovered (e.g. `find_call_path` needs at least
  one real edge to exist).
  """
  @spec pick_tasks(LibGraph.t()) :: map()
  def pick_tasks(graph) do
    %{
      get_callers: pick_get_callers(graph),
      get_callees: pick_get_callees(graph),
      find_call_path: pick_find_call_path(graph),
      search_code: pick_search_code(graph)
    }
  end

  defp pick_get_callers(graph) do
    case pick_highest_in_degree(graph) do
      nil -> nil
      qualified_name -> %{qualified_name: qualified_name} |> Map.merge(split(qualified_name))
    end
  end

  defp pick_get_callees(graph) do
    case pick_highest_out_degree(graph) do
      nil -> nil
      qualified_name -> %{qualified_name: qualified_name} |> Map.merge(split(qualified_name))
    end
  end

  defp pick_find_call_path(graph) do
    with from when not is_nil(from) <- pick_highest_out_degree(graph),
         [first_hop | _] <- LibGraph.out_neighbors(graph, from) do
      to =
        case LibGraph.out_neighbors(graph, first_hop) do
          [second_hop | _] -> second_hop
          [] -> first_hop
        end

      %{
        from: Map.merge(%{qualified_name: from}, split(from)),
        to: Map.merge(%{qualified_name: to}, split(to))
      }
    else
      _ -> nil
    end
  end

  defp pick_search_code(graph) do
    case pick_highest_in_degree(graph) do
      nil ->
        %{exact_name_query: nil, exact_name_term: nil, conceptual_query: @conceptual_query}

      qualified_name ->
        bare_name = qualified_name |> String.split(":") |> List.last()

        %{
          # Backtick the name: forces beamscope's own exact-match extraction
          # to pick it up regardless of naming convention (see
          # Beamscope.Search.LexicalSearch's documented single-bare-word
          # gap), and `exact_name_term` is the known-good literal grep term
          # for the *baseline* side — deliberately not re-derived via
          # beamscope's own term extraction, which would make the baseline
          # circular (testing beamscope's heuristic against itself instead
          # of an independent "what would a real grep search for").
          exact_name_query: "where is `#{bare_name}` defined",
          exact_name_term: bare_name,
          conceptual_query: @conceptual_query
        }
    end
  end

  defp pick_highest_in_degree(graph) do
    graph
    |> real_vertices()
    |> Enum.filter(&(LibGraph.in_degree(graph, &1) > 0))
    |> Enum.max_by(&LibGraph.in_degree(graph, &1), fn -> nil end)
  end

  defp pick_highest_out_degree(graph) do
    graph
    |> real_vertices()
    |> Enum.filter(&(LibGraph.out_degree(graph, &1) > 0))
    |> Enum.max_by(&LibGraph.out_degree(graph, &1), fn -> nil end)
  end

  # Excludes the synthetic "?:name" nodes the extractor uses to mark
  # unresolved dynamic dispatch (see Beamscope.Callgraph.Extractor) — "?"
  # isn't a real module, and every unresolved call site in the whole repo
  # collapses onto the same "?:<name>" node, so it can look like the
  # single highest-in-degree "function" in the graph without being a real,
  # callable target at all. Picking it produced a nonsensical benchmark
  # task and, worse, its bare function name (e.g. "to_string") was common
  # enough to make the baseline grep match nearly the entire repo.
  defp real_vertices(graph) do
    graph
    |> LibGraph.vertices()
    |> Enum.reject(&String.starts_with?(&1, "?:"))
  end

  defp split(qualified_name) do
    [module, function] = String.split(qualified_name, ":", parts: 2)
    %{module: module, function: function}
  end
end
