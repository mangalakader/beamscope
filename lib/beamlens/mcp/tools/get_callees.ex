defmodule Beamlens.MCP.Tools.GetCallees do
  @moduledoc "MCP tool: list every function a given module:function calls."

  use Hermes.Server.Component, type: :tool

  alias Beamlens.Callgraph.{Graph, Store}
  alias Beamlens.MCP.Tools.Params
  alias Hermes.Server.Response

  schema do
    field :repo_path, :string,
      required: true,
      description: "Absolute or relative path to the repo to query (built/cached on first use)"

    field :module, :string, required: true, description: "Module name of the target function"
    field :function, :string, required: true, description: "Name of the target function"
  end

  @impl true
  def execute(params, frame) do
    repo_path = Params.get(params, "repo_path")
    module = Params.get(params, "module")
    function = Params.get(params, "function")

    graph = Store.get_or_build(repo_path)
    qualified = Graph.qualified_name(module, function)
    callees = Graph.callees(graph, qualified)

    {:reply, Response.structured(Response.tool(), %{qualified_name: qualified, callees: callees}), frame}
  end
end
