defmodule Beamlens.MCP.ProtocolTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Protocol

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "initialize returns protocol version, capabilities, and server info" do
    assert {:ok, response} = Protocol.handle(%{"method" => "initialize", "id" => 1})

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert response["result"]["protocolVersion"]
    assert response["result"]["capabilities"] == %{"tools" => %{}}
    assert response["result"]["serverInfo"]["name"] == "beamlens"
  end

  test "tools/list returns all three tools with name/description/inputSchema" do
    assert {:ok, response} = Protocol.handle(%{"method" => "tools/list", "id" => 2})

    names = Enum.map(response["result"]["tools"], & &1["name"])
    assert Enum.sort(names) == ["find_call_path", "get_callees", "get_callers"]

    for tool <- response["result"]["tools"] do
      assert is_binary(tool["description"])
      assert tool["inputSchema"]["type"] == "object"
    end
  end

  test "tools/call dispatches to the right tool and returns structuredContent" do
    params = %{
      "name" => "get_callees",
      "arguments" => %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}
    }

    assert {:ok, response} = Protocol.handle(%{"method" => "tools/call", "id" => 3, "params" => params})

    result = response["result"]
    assert result["isError"] == false
    assert result["structuredContent"].callees == ["mod_sample:helper"]
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "mod_sample:helper"
  end

  test "tools/call with an unknown tool name returns a JSON-RPC error" do
    params = %{"name" => "does_not_exist", "arguments" => %{}}

    assert {:ok, response} = Protocol.handle(%{"method" => "tools/call", "id" => 4, "params" => params})

    assert response["error"]["code"] == -32_602
    assert response["error"]["message"] =~ "Unknown tool"
  end

  test "tools/call with a missing required argument returns a JSON-RPC error" do
    params = %{"name" => "get_callees", "arguments" => %{"repo_path" => @repo, "module" => "mod_sample"}}

    assert {:ok, response} = Protocol.handle(%{"method" => "tools/call", "id" => 5, "params" => params})

    assert response["error"]["code"] == -32_602
    assert response["error"]["message"] =~ "function"
  end

  test "an unrecognized method with an id returns method-not-found" do
    assert {:ok, response} = Protocol.handle(%{"method" => "not/a/real/method", "id" => 6})

    assert response["error"]["code"] == -32_601
  end

  test "a notification (no id) gets no response" do
    assert Protocol.handle(%{"method" => "notifications/initialized"}) == :no_reply
  end
end
