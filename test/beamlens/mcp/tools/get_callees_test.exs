defmodule Beamlens.MCP.Tools.GetCalleesTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Tools.GetCallees

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "returns everything the given module:function calls" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}

    assert {:ok, content} = GetCallees.call(params)
    assert content.qualified_name == "mod_sample:start"
    assert content.callees == ["mod_sample:helper"]
  end

  test "returns a remote call target" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "helper"}

    assert {:ok, content} = GetCallees.call(params)
    assert content.callees == ["gen_mod:get_module_opt"]
  end
end
