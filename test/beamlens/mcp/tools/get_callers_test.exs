defmodule Beamlens.MCP.Tools.GetCallersTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Tools.GetCallers

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "returns everything that calls the given module:function" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "helper"}

    assert {:ok, content} = GetCallers.call(params)
    assert content.qualified_name == "mod_sample:helper"
    assert content.callers == ["mod_sample:start"]
  end

  test "returns an empty list for a function with no callers" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}

    assert {:ok, content} = GetCallers.call(params)
    assert content.callers == []
  end
end
