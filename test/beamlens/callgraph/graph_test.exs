defmodule Beamlens.Callgraph.GraphTest do
  use ExUnit.Case, async: true

  alias Beamlens.Callgraph.{Extractor, Graph}

  @fixtures Path.join([File.cwd!(), "priv", "fixtures"])

  defp fixture(name), do: Path.join(@fixtures, name)

  setup do
    {defs, edges} = Extractor.extract_from_file(fixture("mod_fake_backend.erl"))
    %{graph: Graph.build(defs, edges)}
  end

  test "qualified_name/2 joins module and name with a colon" do
    assert Graph.qualified_name("mod_fake_backend", "get_user") == "mod_fake_backend:get_user"
  end

  test "callees/2 returns everything a function calls, including unresolved dynamic calls", %{
    graph: graph
  } do
    callees = Graph.callees(graph, "mod_fake_backend:get_user")

    assert "gen_mod:get_module_opt" in callees
    assert "?:get_user" in callees
  end

  test "callers/2 returns everything that calls a given function", %{graph: graph} do
    callers = Graph.callers(graph, "gen_mod:get_module_opt")

    assert "mod_fake_backend:get_user" in callers
    assert "mod_fake_backend:save_user" in callers
  end

  test "shortest_path/3 finds a direct path", %{graph: graph} do
    assert Graph.shortest_path(graph, "mod_fake_backend:get_user", "gen_mod:get_module_opt") ==
             ["mod_fake_backend:get_user", "gen_mod:get_module_opt"]
  end

  test "shortest_path/3 returns nil when no path exists", %{graph: graph} do
    assert Graph.shortest_path(graph, "mod_fake_backend:start", "gen_mod:get_module_opt") == nil
  end

  test "shortest_path_with_locations/3 enriches each hop, leaving unresolved ones bare", %{
    graph: graph
  } do
    assert [
             %{qualified_name: "mod_fake_backend:get_user", file_path: file_path, start_line: 18},
             %{qualified_name: "gen_mod:get_module_opt"} = target
           ] =
             Graph.shortest_path_with_locations(
               graph,
               "mod_fake_backend:get_user",
               "gen_mod:get_module_opt"
             )

    assert file_path =~ "mod_fake_backend.erl"
    refute Map.has_key?(target, :file_path)
  end

  test "shortest_path_with_locations/3 returns nil when no path exists", %{graph: graph} do
    assert Graph.shortest_path_with_locations(
             graph,
             "mod_fake_backend:start",
             "gen_mod:get_module_opt"
           ) ==
             nil
  end

  test "defs/1 returns every known definition with its location, excluding unresolved nodes", %{
    graph: graph
  } do
    defs = Graph.defs(graph)
    by_name = Map.new(defs, &{&1.qualified_name, &1})

    assert %{file_path: file_path, start_line: 18, end_line: end_line} =
             by_name["mod_fake_backend:get_user"]

    assert file_path =~ "mod_fake_backend.erl"
    assert end_line >= 18

    # gen_mod:get_module_opt and ?:get_user are edge endpoints only (no def
    # in this fixture) — must not show up as known definitions.
    refute Map.has_key?(by_name, "gen_mod:get_module_opt")
    refute Map.has_key?(by_name, "?:get_user")
  end

  test "callers_with_locations/2 enriches each caller with its def location", %{graph: graph} do
    callers = Graph.callers_with_locations(graph, "gen_mod:get_module_opt")

    assert %{qualified_name: "mod_fake_backend:get_user", file_path: file_path, start_line: 18} =
             Enum.find(callers, &(&1.qualified_name == "mod_fake_backend:get_user"))

    assert file_path =~ "mod_fake_backend.erl"
  end

  test "callees_with_locations/2 enriches known callees, leaves unresolved ones bare", %{
    graph: graph
  } do
    callees = Graph.callees_with_locations(graph, "mod_fake_backend:get_user")

    # gen_mod:get_module_opt has no def in this fixture — no location fields.
    assert %{qualified_name: "gen_mod:get_module_opt"} =
             gen_mod = Enum.find(callees, &(&1.qualified_name == "gen_mod:get_module_opt"))

    refute Map.has_key?(gen_mod, :file_path)
  end

  test "to_node_link_json/1 produces valid JSON with nodes and edges", %{graph: graph} do
    json = Graph.to_node_link_json(graph)
    decoded = Jason.decode!(json)

    assert decoded["directed"] == true
    assert decoded["multigraph"] == true
    assert is_list(decoded["nodes"])
    assert is_list(decoded["edges"])
    assert Enum.any?(decoded["nodes"], &(&1["id"] == "mod_fake_backend:get_user"))
  end
end
