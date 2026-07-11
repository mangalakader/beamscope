defmodule Beamlens.MCP.Tools.GetCallers do
  @moduledoc "MCP tool: list every function that calls a given module:function."

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
    callers = Graph.callers(graph, qualified)

    {:reply, Response.structured(Response.tool(), %{qualified_name: qualified, callers: callers}), frame}
  end
end
