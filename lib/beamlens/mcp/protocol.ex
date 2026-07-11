defmodule Beamlens.MCP.Protocol do
  @moduledoc """
  Minimal MCP (JSON-RPC 2.0 over HTTP) dispatch: `initialize`, `tools/list`,
  `tools/call`. Built directly on Jason-decoded maps rather than a
  protocol library — this project only needs a handful of stateless tools,
  so a full client/server SDK (session tracking, SSE, batching, capability
  negotiation beyond `tools`) is more machinery than the problem calls
  for. Batch requests (a JSON array of messages in one body) aren't
  supported — each HTTP request is exactly one JSON-RPC message.
  """

  require Logger

  alias Beamlens.MCP.Tools.{FindCallPath, GetCallees, GetCallers, SearchCode}

  @protocol_version "2025-03-26"
  @tools [GetCallers, GetCallees, FindCallPath, SearchCode]

  @doc """
  Handles one decoded JSON-RPC message. Returns `{:ok, response_map}` to
  send back, or `:no_reply` for notifications (no `id`), which get no
  response body per the JSON-RPC spec.
  """
  @spec handle(map()) :: {:ok, map()} | :no_reply
  def handle(%{"method" => "initialize", "id" => id}) do
    ok(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "beamlens", "version" => version()}
    })
  end

  def handle(%{"method" => "tools/list", "id" => id}) do
    tools =
      Enum.map(@tools, fn mod ->
        %{
          "name" => mod.name(),
          "description" => mod.description(),
          "inputSchema" => mod.input_schema()
        }
      end)

    ok(id, %{"tools" => tools})
  end

  def handle(%{"method" => "tools/call", "id" => id, "params" => params}) do
    with {:ok, name} <- fetch(params, "name"),
         {:ok, tool} <- find_tool(name),
         arguments = Map.get(params, "arguments", %{}),
         :ok <- validate_required(tool, arguments) do
      case safe_call(tool, arguments) do
        {:ok, data} -> ok(id, tool_result(data))
        {:error, reason} -> ok(id, tool_error(reason))
      end
    else
      {:error, reason} -> err(id, -32_602, reason)
    end
  end

  def handle(%{"id" => id}), do: err(id, -32_601, "Method not found")
  # Notifications (no "id") get no response, including unrecognized ones.
  def handle(_notification), do: :no_reply

  # Last-resort safety net: a tool implementation is expected to return
  # {:error, reason} for anything foreseeable, but if something still raises
  # or exits (e.g. a GenServer.call to a store that crashed for an
  # unanticipated reason), surface it as a normal JSON-RPC tool error
  # instead of letting it escape as a bare, connection-dropping 500.
  defp safe_call(tool, arguments) do
    tool.call(arguments)
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:error, "Internal error: #{Exception.message(e)}"}
  catch
    :exit, reason ->
      Logger.error("tool call exited: #{inspect(reason)}")
      {:error, "Internal error: tool call exited: #{inspect(reason)}"}
  end

  defp find_tool(name) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil -> {:error, "Unknown tool: #{name}"}
      tool -> {:ok, tool}
    end
  end

  defp validate_required(tool, arguments) do
    required = get_in(tool.input_schema(), ["required"]) || []
    missing = Enum.filter(required, &(not is_binary(Map.get(arguments, &1))))

    case missing do
      [] -> :ok
      fields -> {:error, "Missing or invalid required argument(s): #{Enum.join(fields, ", ")}"}
    end
  end

  defp fetch(map, key) do
    case Map.get(map, key) do
      nil -> {:error, "Missing required field: #{key}"}
      value -> {:ok, value}
    end
  end

  defp tool_result(data) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(data)}],
      "structuredContent" => data,
      "isError" => false
    }
  end

  defp tool_error(reason) do
    %{"content" => [%{"type" => "text", "text" => reason}], "isError" => true}
  end

  defp ok(id, result), do: {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}

  defp err(id, code, message),
    do:
      {:ok, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}}

  defp version, do: to_string(Application.spec(:beamlens, :vsn))
end
