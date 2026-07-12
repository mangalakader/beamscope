defmodule Beamscope.MCP.Tools.GetCalleesTest do
  use ExUnit.Case, async: false

  alias Beamscope.MCP.Tools.GetCallees

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "returns everything the given module:function calls, with locations" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}

    assert {:ok, content} = GetCallees.call(params)
    assert content.qualified_name == "mod_sample:start"

    assert [%{qualified_name: "mod_sample:helper", file_path: file_path, start_line: 10}] =
             content.callees

    assert file_path =~ "mod_sample.erl"
  end

  test "returns a remote call target with no location (not defined in this repo)" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "helper"}

    assert {:ok, content} = GetCallees.call(params)
    assert [%{qualified_name: "gen_mod:get_module_opt"} = callee] = content.callees
    refute Map.has_key?(callee, :file_path)
  end
end
