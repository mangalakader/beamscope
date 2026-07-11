defmodule Mix.Tasks.Beamlens.Mcp do
  @moduledoc """
  Starts the Beamlens MCP server over streamable HTTP.

      mix beamlens.mcp
      mix beamlens.mcp --port 9877

  Exposes `get_callers`, `get_callees`, `find_call_path` as MCP tools at
  `http://localhost:<port>/mcp`, backed by `Beamlens.Callgraph.Store`.
  Each tool call takes an explicit `repo_path`; the graph for that path is
  built once and cached across calls within this server process's
  lifetime.

  ## Why HTTP, not stdio

  Stdio is the transport most local MCP clients (Claude Desktop, Claude
  Code) expect for a spawned subprocess, and was the original plan here.
  It's not used: `hermes_mcp` 0.14.1's stdio transport has a confirmed bug
  where every single (non-batched) JSON-RPC message crashes the
  connection — `Message.decode/1` always returns a list of messages
  (supporting newline-delimited batches), but
  `Hermes.Server.Transport.STDIO.process_message/2` doesn't unwrap that
  list before dispatching, so it always receives `[message]` where a bare
  map is expected. Reproduced directly against the library, not just in
  this project's own code; no newer release exists to pick up a fix as of
  this writing. HTTP transport doesn't share this bug (it decodes each
  request body as a single map on a different code path) and is used here
  instead, at the cost of not matching the "spawn me as a subprocess"
  config shape most desktop clients default to for local servers.
  """

  @shortdoc "Starts the Beamlens MCP server (streamable HTTP transport)"

  use Mix.Task

  @default_port 9877

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [port: :integer])
    port = Keyword.get(opts, :port, @default_port)

    Mix.Task.run("app.start")

    # Not started by Hermes' own Application by default — it's scoped to
    # whichever app actually runs a server, not always-on infrastructure.
    {:ok, _registry_pid} = Registry.start_link(keys: :unique, name: Hermes.Server.Registry)

    {:ok, _server_pid} =
      Hermes.Server.Supervisor.start_link(Beamlens.MCP.Server, transport: {:streamable_http, []})

    {:ok, _bandit_pid} = Bandit.start_link(plug: Beamlens.MCP.Router, port: port)

    Mix.shell().info("beamlens MCP server listening on http://localhost:#{port}/mcp")

    Process.sleep(:infinity)
  end
end
