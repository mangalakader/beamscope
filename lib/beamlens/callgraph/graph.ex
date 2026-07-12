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

  @doc """
  Every function that calls `qualified_name`, enriched with its definition
  location (`file_path`/`start_line`/`end_line`) when known. A caller with
  no known def (e.g. an unresolved dynamic-dispatch node) comes back with
  just `qualified_name` — honest, not an error.
  """
  @spec callers_with_locations(LibGraph.t(), String.t()) :: [map()]
  def callers_with_locations(graph, qualified_name) do
    graph |> callers(qualified_name) |> Enum.map(&location_entry(graph, &1))
  end

  @doc "Every function `qualified_name` calls, enriched with location like `callers_with_locations/2`."
  @spec callees_with_locations(LibGraph.t(), String.t()) :: [map()]
  def callees_with_locations(graph, qualified_name) do
    graph |> callees(qualified_name) |> Enum.map(&location_entry(graph, &1))
  end

  defp location_entry(graph, qualified_name) do
    label = graph |> LibGraph.vertex_labels(qualified_name) |> List.first() || %{}
    Map.merge(%{qualified_name: qualified_name}, label)
  end

  @doc """
  Every known function definition in the graph — `qualified_name` plus its
  `file_path`/`start_line`/`end_line`. Vertices added only as edge endpoints
  (e.g. unresolved/dynamic calls) have no location label and are excluded.
  """
  @spec defs(LibGraph.t()) :: [map()]
  def defs(graph) do
    graph
    |> LibGraph.vertices()
    |> Enum.map(&location_entry(graph, &1))
    |> Enum.filter(&Map.has_key?(&1, :file_path))
  end

  @spec shortest_path(LibGraph.t(), String.t(), String.t()) :: [String.t()] | nil
  def shortest_path(graph, from, to), do: LibGraph.get_shortest_path(graph, from, to)

  @doc """
  Shortest call path from `from` to `to`, like `shortest_path/3`, but with
  each hop enriched with its definition location like
  `callers_with_locations/2`. `nil` if no path exists.
  """
  @spec shortest_path_with_locations(LibGraph.t(), String.t(), String.t()) :: [map()] | nil
  def shortest_path_with_locations(graph, from, to) do
    case shortest_path(graph, from, to) do
      nil -> nil
      path -> Enum.map(path, &location_entry(graph, &1))
    end
  end

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

  @doc """
  Rebuilds a graph from `to_node_link_json/1`'s output — used to reload a
  persisted call graph (`Beamlens.Callgraph.Store`) without re-walking and
  re-parsing the repo from source.
  """
  @spec from_node_link_json(String.t()) :: LibGraph.t()
  def from_node_link_json(json) do
    %{"nodes" => nodes, "edges" => edges} = Jason.decode!(json)

    graph =
      Enum.reduce(nodes, LibGraph.new(type: :directed), fn node, g ->
        id = Map.fetch!(node, "id")

        case node_label(node) do
          label when map_size(label) > 0 -> LibGraph.add_vertex(g, id, label)
          _empty -> LibGraph.add_vertex(g, id)
        end
      end)

    Enum.reduce(edges, graph, fn edge, g ->
      %{"source" => source, "target" => target} = edge
      label = %{file_path: edge["file_path"], line: edge["line"]}
      LibGraph.add_edge(g, source, target, label: label)
    end)
  end

  defp node_label(%{"file_path" => file_path, "start_line" => start_line, "end_line" => end_line}) do
    %{file_path: file_path, start_line: start_line, end_line: end_line}
  end

  defp node_label(_node), do: %{}
end
