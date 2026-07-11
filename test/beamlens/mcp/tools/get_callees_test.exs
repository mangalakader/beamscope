defmodule Beamlens.MCP.Tools.GetCalleesTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Tools.GetCallees
  alias Hermes.Server.{Frame, Response}

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "returns everything the given module:function calls" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}

    assert {:reply, %Response{structured_content: content}, %Frame{}} =
             GetCallees.execute(params, Frame.new())

    assert content.qualified_name == "mod_sample:start"
    assert content.callees == ["mod_sample:helper"]
  end

  test "returns a remote call target" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "helper"}

    assert {:reply, %Response{structured_content: content}, _frame} =
             GetCallees.execute(params, Frame.new())

    assert content.callees == ["gen_mod:get_module_opt"]
  end
end
