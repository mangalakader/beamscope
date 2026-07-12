defmodule Beamlens.Benchmark.TaskDiscoveryTest do
  use ExUnit.Case, async: true

  alias Beamlens.Benchmark.TaskDiscovery
  alias Beamlens.Callgraph.{Extractor, Graph}
  alias Elixir.Graph, as: LibGraph

  @fixtures Path.join([File.cwd!(), "priv", "fixtures"])

  defp fixture(name), do: Path.join(@fixtures, name)

  setup do
    {defs, edges} = Extractor.extract_from_file(fixture("mod_fake_backend.erl"))
    %{graph: Graph.build(defs, edges)}
  end

  test "get_callers picks the unambiguous highest-in-degree node", %{graph: graph} do
    tasks = TaskDiscovery.pick_tasks(graph)

    assert %{
             qualified_name: "gen_mod:get_module_opt",
             module: "gen_mod",
             function: "get_module_opt"
           } =
             tasks.get_callers
  end

  test "get_callees picks a real node with the maximum out-degree", %{graph: graph} do
    tasks = TaskDiscovery.pick_tasks(graph)
    picked = tasks.get_callees.qualified_name
    max_out_degree = LibGraph.out_degree(graph, picked)

    assert max_out_degree > 0

    assert Enum.all?(LibGraph.vertices(graph), fn v ->
             LibGraph.out_degree(graph, v) <= max_out_degree
           end)
  end

  test "find_call_path picks a pair with a genuine path between them", %{graph: graph} do
    tasks = TaskDiscovery.pick_tasks(graph)
    %{from: from, to: to} = tasks.find_call_path

    assert Graph.shortest_path(graph, from.qualified_name, to.qualified_name) != nil
  end

  test "search_code wraps the picked name in backticks (forces exact-match extraction regardless of naming convention)",
       %{graph: graph} do
    tasks = TaskDiscovery.pick_tasks(graph)

    assert tasks.search_code.exact_name_query == "where is `get_module_opt` defined"
    assert tasks.search_code.exact_name_term == "get_module_opt"
    assert is_binary(tasks.search_code.conceptual_query)
  end

  test "pick_tasks/1 degrades to nils rather than crashing on an empty graph" do
    empty_graph = Graph.build([], [])
    tasks = TaskDiscovery.pick_tasks(empty_graph)

    assert tasks.get_callers == nil
    assert tasks.get_callees == nil
    assert tasks.find_call_path == nil
    assert tasks.search_code.exact_name_query == nil
  end
end
