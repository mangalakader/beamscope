defmodule Beamlens.Callgraph.Graph do
  @moduledoc """
  Builds a `libgraph`-backed call graph from `Extractor`'s defs/edges.

  Nodes are `"module:name"` qualified strings — the same convention
  `build_callgraph.py`'s `FunctionDef.qualified_name`/`CallEdge.*_qualified`
  use — so results stay directly diffable against the existing
  `shared/mongooseim_callgraph.json` baseline via `to_node_link_json/1`,
  which mirrors NetworkX's `node_link_data` shape (`directed`,
  `multigraph`, `graph`, `nodes`, `edges` with `source`/`target`/`key`).
  """

  alias Graph, as: LibGraph

  @spec build([map()], [map()]) :: LibGraph.t()
  def build(defs, edges) do
    graph =
      Enum.reduce(defs, LibGraph.new(type: :directed), fn def, g ->
        LibGraph.add_vertex(g, qualified_name(def.module, def.name), %{
          file_path: def.file_path,
          start_line: def.start_line,
          end_line: def.end_line
        })
      end)

    Enum.reduce(edges, graph, fn edge, g ->
      caller = qualified_name(edge.caller_module, edge.caller_name)
      callee = qualified_name(edge.callee_module, edge.callee_name)

      g
      |> LibGraph.add_vertex(caller)
      |> LibGraph.add_vertex(callee)
      |> LibGraph.add_edge(caller, callee, label: %{file_path: edge.file_path, line: edge.line})
    end)
  end

  @spec qualified_name(String.t(), String.t()) :: String.t()
  def qualified_name(module, name), do: "#{module}:#{name}"

  @spec callers(LibGraph.t(), String.t()) :: [String.t()]
  def callers(graph, qualified_name), do: LibGraph.in_neighbors(graph, qualified_name)

  @spec callees(LibGraph.t(), String.t()) :: [String.t()]
  def callees(graph, qualified_name), do: LibGraph.out_neighbors(graph, qualified_name)

  @spec shortest_path(LibGraph.t(), String.t(), String.t()) :: [String.t()] | nil
  def shortest_path(graph, from, to), do: LibGraph.get_shortest_path(graph, from, to)

  @spec to_node_link_json(LibGraph.t()) :: String.t()
  def to_node_link_json(graph) do
    nodes =
      Enum.map(LibGraph.vertices(graph), fn v ->
        label = graph |> LibGraph.vertex_labels(v) |> List.first() || %{}
        Map.put(label, :id, v)
      end)

    edges =
      graph
      |> LibGraph.edges()
      |> Enum.with_index()
      |> Enum.map(fn {%Graph.Edge{v1: v1, v2: v2, label: label}, idx} ->
        label = label || %{}

        %{source: v1, target: v2, key: idx}
        |> Map.merge(Map.take(label, [:file_path, :line]))
      end)

    Jason.encode!(%{
      directed: true,
      multigraph: true,
      graph: %{},
      nodes: nodes,
      edges: edges
    })
  end
end
