defmodule Beamlens.MCP.Server do
  @moduledoc """
  MCP server exposing the call graph as tools: `get_callers`, `get_callees`,
  `find_call_path`. Started via `mix beamlens.mcp` (stdio transport), not
  part of the default application supervision tree — an MCP server over
  stdio owns the process's stdin/stdout, so it shouldn't be running
  whenever `mix test`/`iex -S mix`/etc. boot the app.

  No `search_code` tool yet — no embedding/Qdrant pipeline exists.
  """

  use Hermes.Server,
    name: "beamlens",
    version: Mix.Project.config()[:version] || "0.1.0",
    capabilities: [:tools]

  component Beamlens.MCP.Tools.GetCallers
  component Beamlens.MCP.Tools.GetCallees
  component Beamlens.MCP.Tools.FindCallPath

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
