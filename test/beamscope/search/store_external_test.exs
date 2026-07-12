defmodule Beamscope.Search.StoreExternalTest do
  @moduledoc """
  Real end-to-end tests against the actual Bumblebee/Torchx embedding
  path — first run downloads the model (~90MB) and builds a real index.
  Excluded from the default `mix test` run (see test/test_helper.exs);
  run with `mix test --include external`.
  """

  use ExUnit.Case, async: false

  alias Beamscope.Search.Store

  @moduletag :external
  # Generous timeout: first call downloads/loads the model.
  @moduletag timeout: 120_000

  @repo Path.join([File.cwd!(), "priv", "fixtures", "mcp_repo"])
  @dets_path Path.join([@repo, ".beamscope", "search.dets"])

  setup_all do
    assert :ok = Store.get_or_build(@repo)
    on_exit(fn -> File.rm_rf!(Path.join(@repo, ".beamscope")) end)
    :ok
  end

  test "get_or_build/2 builds and persists an index on disk" do
    assert Store.indexed?(@repo)
    assert File.exists?(@dets_path)
  end

  test "search/3 returns scored, sorted, correctly-shaped results" do
    assert {:ok, results} =
             Store.search(@repo, "look up a module's configured backend option", limit: 3)

    assert length(results) <= 3
    assert length(results) > 0

    for %{
          file_path: file_path,
          symbol: symbol,
          start_line: start_line,
          end_line: end_line,
          kind: kind,
          score: score
        } <-
          results do
      assert is_binary(file_path)
      assert is_binary(symbol)
      assert is_integer(start_line)
      assert is_integer(end_line)
      assert kind in [:function, :attribute, :macro, :text_window]
      assert is_float(score)
    end

    scores = Enum.map(results, & &1.score)
    assert scores == Enum.sort(scores, :desc)
  end

  test "reindex/2 rebuilds the index from scratch" do
    assert :ok = Store.reindex(@repo)
    assert Store.indexed?(@repo)
  end

  test "a chunk with invalid UTF-8 text doesn't crash the shared Embeddings/Store singletons" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamscope_mixed_encoding_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "good.md"), """
    # Notes

    Something about how session tokens get validated on login.
    """)

    # Genuinely invalid UTF-8 (a lone UTF-16 BOM byte sequence followed by
    # bytes that don't form valid UTF-8 on their own) — generated at test
    # time rather than committed as a binary fixture file.
    File.write!(Path.join(dir, "invalid.txt"), <<0xFF, 0xFE, 0x00, 0x01>>)

    on_exit(fn -> File.rm_rf!(dir) end)

    embeddings_pid = Process.whereis(Beamscope.Embeddings)
    store_pid = Process.whereis(Store)

    assert :ok = Store.get_or_build(dir)

    assert Process.whereis(Beamscope.Embeddings) == embeddings_pid
    assert Process.whereis(Store) == store_pid
    assert Store.indexed?(dir)

    assert {:ok, results} = Store.search(dir, "how are session tokens validated", limit: 5)
    assert Enum.any?(results, &(&1.file_path =~ "good.md"))
  end
end
