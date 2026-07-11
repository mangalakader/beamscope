defmodule Beamlens.MCP.Tools.GetCallersTest do
  use ExUnit.Case, async: false

  alias Beamlens.MCP.Tools.GetCallers

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "returns everything that calls the given module:function, with locations" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "helper"}

    assert {:ok, content} = GetCallers.call(params)
    assert content.qualified_name == "mod_sample:helper"

    assert [%{qualified_name: "mod_sample:start", file_path: file_path, start_line: 4}] =
             content.callers

    assert file_path =~ "mod_sample.erl"
  end

  test "returns an empty list for a function with no callers" do
    params = %{"repo_path" => @repo, "module" => "mod_sample", "function" => "start"}

    assert {:ok, content} = GetCallers.call(params)
    assert content.callers == []
  end
end
