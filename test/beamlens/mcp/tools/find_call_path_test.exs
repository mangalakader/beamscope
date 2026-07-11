defmodule Beamlens.MCP.Tools.FindCallPathTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Tools.FindCallPath
  alias Hermes.Server.{Frame, Response}

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "finds a multi-hop path through an intermediate function" do
    params = %{
      "repo_path" => @repo,
      "from_module" => "mod_sample",
      "from_function" => "start",
      "to_module" => "gen_mod",
      "to_function" => "get_module_opt"
    }

    assert {:reply, %Response{structured_content: content}, %Frame{}} =
             FindCallPath.execute(params, Frame.new())

    assert content.path == ["mod_sample:start", "mod_sample:helper", "gen_mod:get_module_opt"]
  end

  test "returns nil when no path exists" do
    params = %{
      "repo_path" => @repo,
      "from_module" => "mod_sample",
      "from_function" => "stop",
      "to_module" => "gen_mod",
      "to_function" => "get_module_opt"
    }

    assert {:reply, %Response{structured_content: content}, _frame} =
             FindCallPath.execute(params, Frame.new())

    assert content.path == nil
  end
end
