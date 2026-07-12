defmodule Beamscope.MCP.Tools.FindCallPathTest do
  use ExUnit.Case, async: false

  alias Beamscope.MCP.Tools.FindCallPath

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "finds a multi-hop path through an intermediate function" do
    params = %{
      "repo_path" => @repo,
      "from_module" => "mod_sample",
      "from_function" => "start",
      "to_module" => "gen_mod",
      "to_function" => "get_module_opt"
    }

    assert {:ok, content} = FindCallPath.call(params)

    assert [
             %{qualified_name: "mod_sample:start", file_path: start_file, start_line: 4},
             %{qualified_name: "mod_sample:helper", file_path: helper_file, start_line: 10},
             %{qualified_name: "gen_mod:get_module_opt"} = external
           ] = content.path

    assert start_file =~ "mod_sample.erl"
    assert helper_file == start_file
    refute Map.has_key?(external, :file_path)
  end

  test "returns nil when no path exists" do
    params = %{
      "repo_path" => @repo,
      "from_module" => "mod_sample",
      "from_function" => "stop",
      "to_module" => "gen_mod",
      "to_function" => "get_module_opt"
    }

    assert {:ok, content} = FindCallPath.call(params)
    assert content.path == nil
  end
end
