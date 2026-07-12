defmodule Beamscope.Search.StoreTest do
  use ExUnit.Case, async: false

  alias Beamscope.Search.Store

  test "indexed?/1 is false for a repo that was never queried" do
    refute Store.indexed?("priv/fixtures/never_queried_search_repo")
  end

  test "get_or_build/2 reuses an existing on-disk index and cleans up a stray interrupted-build tmp file" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamscope_search_atomic_test_#{System.unique_integer([:positive])}"
      )

    beamscope_dir = Path.join(dir, ".beamscope")
    File.mkdir_p!(beamscope_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    dets_path = Path.join(beamscope_dir, "search.dets")
    table_name = :"beamscope_search_atomic_seed_#{System.unique_integer([:positive])}"

    {:ok, table} = :dets.open_file(table_name, file: to_charlist(dets_path), type: :set)

    :dets.insert(
      table,
      {"seed.ex:1", [0.1, 0.2],
       %{file_path: "seed.ex", symbol: "seed", start_line: 1, end_line: 2, kind: :function}}
    )

    :dets.close(table)

    # Simulates a leftover from a previous build that got killed mid-way,
    # before it was renamed into place.
    stray_tmp = "#{dets_path}.tmp.999999"
    File.write!(stray_tmp, "not a real dets file")

    assert :ok = Store.get_or_build(dir)
    assert Store.indexed?(dir)

    refute File.exists?(stray_tmp)
    assert File.exists?(dets_path)
  end
end
