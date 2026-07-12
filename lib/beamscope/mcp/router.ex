defmodule Beamscope.MCP.Router do
  @moduledoc """
  HTTP endpoint for the MCP server. A single `POST /mcp` accepting one
  JSON-RPC 2.0 message per request, dispatched via `Beamscope.MCP.Protocol`.
  """

  use Plug.Router

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    case Beamscope.MCP.Protocol.handle(conn.body_params) do
      {:ok, response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      :no_reply ->
        send_resp(conn, 202, "")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
