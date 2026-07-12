defmodule Beamscope.MCP.Tools.SearchCodeTest do
  use ExUnit.Case, async: false

  alias Beamscope.MCP.Tools.SearchCode

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  # Generous timeout: first call downloads/loads the model.
  @moduletag timeout: 120_000

  # No on_exit cleanup here: this fixture path is shared with
  # Beamscope.Search.StoreExternalTest via the same singleton
  # Beamscope.Search.Store process. Deleting the on-disk .beamscope/ dir here
  # without also evicting the Store's in-memory cache would desync the
  # two — a later "file exists on disk" assertion in that module could
  # fail even though the (correct, in-memory) index is still usable.
  # .beamscope/ is gitignored, so leaving it on disk between test runs is
  # harmless; StoreExternalTest owns cleanup for this path.

  @tag :external
  test "returns semantically relevant results with file/line/symbol metadata" do
    params = %{
      "repo_path" => @repo,
      "query" => "module backend configuration lookup",
      "limit" => 3
    }

    assert {:ok, content} = SearchCode.call(params)
    assert content.query == "module backend configuration lookup"

    assert [%{file_path: _, symbol: _, start_line: _, end_line: _, kind: _, score: _} | _] =
             content.semantic_matches
  end

  test "exact_matches works with no embedding dependency for an exact-name query" do
    params = %{
      "repo_path" => @repo,
      "query" => "where is get_module_opt called",
      "limit" => 3
    }

    assert {:ok, content} = SearchCode.call(params)

    assert [%{file_path: file_path, line: line, text: text, match_kind: _} | _] =
             content.exact_matches

    assert file_path =~ "mod_sample.erl"
    assert is_integer(line)
    assert text =~ "get_module_opt"
  end

  test "exact_matches ranks the real definition above a call site referencing the same name" do
    # "helper" alone isn't identifier-like (no underscore/camelCase), so
    # backtick it to force extraction — matches mod_sample.erl's real
    # `helper(Host) -> ...` definition (line 10) and its call site inside
    # `start/1` (line 5).
    params = %{"repo_path" => @repo, "query" => "where is `helper` defined", "limit" => 5}

    assert {:ok, content} = SearchCode.call(params)
    assert [first | _] = content.exact_matches

    assert first.match_kind == :definition
    assert first.text =~ "helper(Host) ->"
    assert Enum.any?(content.exact_matches, &(&1.match_kind == :reference))
  end
end
