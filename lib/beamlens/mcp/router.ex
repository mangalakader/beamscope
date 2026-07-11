defmodule Beamlens.MCP.Router do
  @moduledoc """
  Plug router mounting the MCP streamable-HTTP endpoint. `Hermes.Server`'s
  `:streamable_http` transport is message-routing logic only — it doesn't
  start an HTTP listener itself, so the consuming app (here, the
  `beamlens.mcp` mix task) is expected to mount this Plug and start its
  own HTTP server (Bandit) around it.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/mcp", to: Hermes.Server.Transport.StreamableHTTP.Plug, init_opts: [server: Beamlens.MCP.Server])
end
