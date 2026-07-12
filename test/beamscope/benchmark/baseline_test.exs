defmodule Beamscope.Benchmark.BaselineTest do
  use ExUnit.Case, async: true

  alias Beamscope.Benchmark.Baseline

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "measure/2 finds and fully reads every file containing any of the terms" do
    result = Baseline.measure(@repo, ["helper"])

    assert result.bytes > 0
    assert result.text =~ "helper"
    assert result.capped? == false
  end

  test "measure/2 returns zero bytes for an empty term list — nothing to grep for" do
    assert Baseline.measure(@repo, []) == %{bytes: 0, text: "", capped?: false}
  end

  test "measure/2 returns zero bytes when no file contains any term" do
    assert Baseline.measure(@repo, ["definitely_not_a_real_identifier_xyz"]) == %{
             bytes: 0,
             text: "",
             capped?: false
           }
  end

  test "measure/2 degrades gracefully for a nonexistent repo_path" do
    assert Baseline.measure("/tmp/beamscope_definitely_does_not_exist", ["helper"]) == %{
             bytes: 0,
             text: "",
             capped?: false
           }
  end

  test "measure/2 caps total bytes read rather than accumulating unbounded content" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamscope_baseline_cap_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Three files, each bigger than a tiny cap, all containing the term.
    for i <- 1..3 do
      File.write!(Path.join(dir, "big_#{i}.ex"), "# needle\n" <> String.duplicate("x", 100))
    end

    result = Baseline.measure(dir, ["needle"], 50)

    assert result.capped? == true
    assert result.bytes >= 50
    # Didn't read all three files worth of content (300+ bytes) once capped.
    assert result.bytes < 300
  end
end
