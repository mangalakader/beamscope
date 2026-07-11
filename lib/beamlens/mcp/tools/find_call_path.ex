defmodule Beamlens.MCP.Tools.FindCallPath do
  @moduledoc "MCP tool: find the shortest call path between two functions, if one exists."

  @behaviour Beamlens.MCP.Tool

  alias Beamlens.Callgraph.{Graph, Store}

  @impl true
  def name, do: "find_call_path"

  @impl true
  def description, do: "Find the shortest call path between two functions, if one exists."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo_path" => %{
          "type" => "string",
          "description" => "Absolute or relative path to the repo to query (built/cached on first use)"
        },
        "from_module" => %{"type" => "string", "description" => "Module name of the starting function"},
        "from_function" => %{"type" => "string", "description" => "Name of the starting function"},
        "to_module" => %{"type" => "string", "description" => "Module name of the target function"},
        "to_function" => %{"type" => "string", "description" => "Name of the target function"}
      },
      "required" => ["repo_path", "from_module", "from_function", "to_module", "to_function"]
    }
  end

  @impl true
  def call(%{
        "repo_path" => repo_path,
        "from_module" => from_module,
        "from_function" => from_function,
        "to_module" => to_module,
        "to_function" => to_function
      }) do
    from = Graph.qualified_name(from_module, from_function)
    to = Graph.qualified_name(to_module, to_function)

    graph = Store.get_or_build(repo_path)
    path = Graph.shortest_path(graph, from, to)

    {:ok, %{from: from, to: to, path: path}}
  end
end
