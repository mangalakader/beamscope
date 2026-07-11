defmodule Beamlens.MCP.Tools.GetCallers do
  @moduledoc "MCP tool: list every function that calls a given module:function."

  @behaviour Beamlens.MCP.Tool

  alias Beamlens.Repo

  @impl true
  def name, do: "get_callers"

  @impl true
  def description, do: "List every function that calls a given module:function."

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
    Repo.callers(repo_path, module, function)
  end
end
