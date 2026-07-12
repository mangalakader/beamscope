defmodule Beamscope.MCP.Tools.GetCallees do
  @moduledoc "MCP tool: list every function a given module:function calls."

  @behaviour Beamscope.MCP.Tool

  alias Beamscope.Repo

  @impl true
  def name, do: "get_callees"

  @impl true
  def description, do: "List every function a given module:function calls."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo_path" => %{
          "type" => "string",
          "description" =>
            "Absolute or relative path to the repo to query (built/cached on first use)"
        },
        "module" => %{"type" => "string", "description" => "Module name of the target function"},
        "function" => %{"type" => "string", "description" => "Name of the target function"}
      },
      "required" => ["repo_path", "module", "function"]
    }
  end

  @impl true
  def call(%{"repo_path" => repo_path, "module" => module, "function" => function}) do
    Repo.callees(repo_path, module, function)
  end
end
