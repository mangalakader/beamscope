defmodule Mix.Tasks.Beamlens.Mcp do
  @moduledoc """
  Starts the Beamlens MCP server over HTTP.

      mix beamlens.mcp
      mix beamlens.mcp --port 9877

  Exposes `get_callers`, `get_callees`, `find_call_path` as MCP tools at
  `http://localhost:<port>/mcp`, backed by `Beamlens.Callgraph.Store`.
  Each tool call takes an explicit `repo_path`; the graph for that path is
  built once and cached across calls within this server process's
  lifetime.

  Built directly on Plug + Bandit + Jason (`Beamlens.MCP.Protocol`/
  `Beamlens.MCP.Router`), not an MCP protocol library — connect an MCP
  client to the URL above as a remote HTTP server rather than spawning
  this as a stdio subprocess.
  """

  @shortdoc "Starts the Beamlens MCP server (HTTP)"

  use Mix.Task

  @default_port 9877

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [port: :integer])
    port = Keyword.get(opts, :port, @default_port)

    Mix.Task.run("app.start")

    {:ok, _bandit_pid} = Bandit.start_link(plug: Beamlens.MCP.Router, port: port)

    Mix.shell().info("beamlens MCP server listening on http://localhost:#{port}/mcp")

    Process.sleep(:infinity)
  end
end
