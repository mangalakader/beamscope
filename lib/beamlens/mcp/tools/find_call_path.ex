defmodule Beamlens.MCP.Tools.FindCallPath do
  @moduledoc "MCP tool: find the shortest call path between two functions, if one exists."

  use Hermes.Server.Component, type: :tool

  alias Beamlens.Callgraph.{Graph, Store}
  alias Beamlens.MCP.Tools.Params
  alias Hermes.Server.Response

  schema do
    field :repo_path, :string,
      required: true,
      description: "Absolute or relative path to the repo to query (built/cached on first use)"

    field :from_module, :string, required: true, description: "Module name of the starting function"
    field :from_function, :string, required: true, description: "Name of the starting function"
    field :to_module, :string, required: true, description: "Module name of the target function"
    field :to_function, :string, required: true, description: "Name of the target function"
  end

  @impl true
  def execute(params, frame) do
    repo_path = Params.get(params, "repo_path")
    from = Graph.qualified_name(Params.get(params, "from_module"), Params.get(params, "from_function"))
    to = Graph.qualified_name(Params.get(params, "to_module"), Params.get(params, "to_function"))

    graph = Store.get_or_build(repo_path)
    path = Graph.shortest_path(graph, from, to)

    {:reply, Response.structured(Response.tool(), %{from: from, to: to, path: path}), frame}
  end
end
