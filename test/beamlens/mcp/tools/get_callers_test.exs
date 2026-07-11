defmodule Beamlens.MCP.Tools.GetCallersTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Tools.GetCallers
  alias Hermes.Server.{Frame, Response}

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "returns everything that calls the given module:function" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "helper"}

    assert {:reply, %Response{structured_content: content}, %Frame{}} =
             GetCallers.execute(params, Frame.new())

    assert content.qualified_name == "mod_sample:helper"
    assert content.callers == ["mod_sample:start"]
  end

  test "returns an empty list for a function with no callers" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}

    assert {:reply, %Response{structured_content: content}, _frame} =
             GetCallers.execute(params, Frame.new())

    assert content.callers == []
  end
end
