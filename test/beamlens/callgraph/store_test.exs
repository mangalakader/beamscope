defmodule Beamlens.Callgraph.StoreTest do
  use ExUnit.Case, async: false

  alias Beamlens.Callgraph.{Graph, Store}

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])

  test "get_or_build/2 builds and caches a graph for a repo path" do
    graph = Store.get_or_build(@repo)

    assert "mod_sample:start" in Elixir.Graph.vertices(graph)
    assert Store.indexed?(@repo)
  end

  test "get_or_build/2 returns the same cached graph on repeated calls" do
    graph1 = Store.get_or_build(@repo)
    graph2 = Store.get_or_build(@repo)

    assert Elixir.Graph.vertices(graph1) == Elixir.Graph.vertices(graph2)
  end

  test "reindex/2 rebuilds and replaces the cached graph" do
    _graph1 = Store.get_or_build(@repo)
    graph2 = Store.reindex(@repo)

    assert Graph.callees(graph2, "mod_sample:start") == ["mod_sample:helper"]
  end

  test "indexed?/1 is false for a repo that was never queried" do
    refute Store.indexed?("priv/fixtures/never_queried_repo")
  end

  test "a crash-inducing build for one repo doesn't wipe another repo's cache" do
    Store.get_or_build(@repo)
    assert Store.indexed?(@repo)
    store_pid = Process.whereis(Store)

    dir =
      Path.join(System.tmp_dir!(), "beamlens_store_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.ln_s!(Path.join(dir, "does_not_exist"), Path.join(dir, "dangling.ex"))
    on_exit(fn -> File.rm_rf!(dir) end)

    # Per-file crashes during the build are caught and recorded as errors
    # (Task.Supervisor.async_stream_nolink), so this still returns a graph
    # rather than crashing the shared Store GenServer.
    Store.get_or_build(dir)

    assert Process.whereis(Store) == store_pid
    assert Store.indexed?(@repo)
  end
end
