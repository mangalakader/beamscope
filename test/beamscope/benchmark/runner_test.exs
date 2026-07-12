defmodule Beamscope.Benchmark.RunnerTest do
  @moduledoc """
  Real end-to-end test against the actual `mcp_repo` fixture and the real
  embedding path — excluded from the default `mix test` run (see
  test/test_helper.exs), run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  alias Beamscope.Benchmark.{Report, Runner}

  @moduletag :external
  @moduletag timeout: 120_000

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "run/1 produces real, honest rows for every auto-discovered task" do
    result = Runner.run(@repo)

    assert result.repo_path == @repo
    assert length(result.rows) == 5

    tasks = Enum.map(result.rows, & &1.task)
    assert "get_callers" in tasks
    assert "get_callees" in tasks
    assert "find_call_path" in tasks
    assert "search_code (exact-name)" in tasks
    assert "search_code (conceptual)" in tasks

    for row <- result.rows do
      assert is_integer(row.baseline_tokens)
      assert is_integer(row.beamscope_tokens)
      assert row.baseline_tokens >= 0
      assert row.beamscope_tokens > 0
    end

    exact_name_row = Enum.find(result.rows, &(&1.task == "search_code (exact-name)"))
    assert exact_name_row.quality_note =~ "PASS"

    assert length(result.timings) == 4
  end

  test "Report.write/2 writes a real, timestamped Markdown file" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamscope_benchmark_report_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    result = Runner.run(@repo)
    assert [path] = Report.write([result], dir)

    assert File.exists?(path)
    assert Path.basename(path) =~ ~r/^benchmark_mcp_repo_.+\.md$/

    content = File.read!(path)
    assert content =~ "# Beamscope benchmark report"
    assert content =~ @repo
    assert content =~ "| Task | Description |"
  end
end
