defmodule Beamlens.Chunking.ErlangChunkerTest do
  use ExUnit.Case, async: true

  alias Beamlens.Chunking.ErlangChunker

  @fixtures Path.join([File.cwd!(), "priv", "fixtures"])

  defp fixture(name), do: Path.join(@fixtures, name)

  defp symbols(chunks), do: Enum.map(chunks, & &1.symbol)

  describe "attributes and functions" do
    test "emits -name attribute symbols and name/arity function symbols" do
      chunks = ErlangChunker.chunk_file(fixture("mod_fake_backend.erl"))

      assert symbols(chunks) == [
               "-module",
               "-behaviour",
               "-export",
               "start/2",
               "stop/1",
               "get_user/2",
               "save_user/3"
             ]
    end

    test "excludes forms belonging to an -include'd header (deliberate fix)" do
      chunks = ErlangChunker.chunk_file(fixture("mod_fake_backend.erl"))

      refute Enum.any?(chunks, &String.contains?(&1.symbol, "record"))
    end

    test "chunking the header directly still produces its own record chunk" do
      chunks = ErlangChunker.chunk_file(fixture("fake_backend.hrl"))

      assert [%{symbol: "-record", kind: :attribute}] = chunks
    end

    test "every chunk carries the source file_path" do
      chunks = ErlangChunker.chunk_file(fixture("mod_fake_backend.erl"))

      assert Enum.all?(chunks, &(&1.file_path == fixture("mod_fake_backend.erl")))
    end
  end

  describe "-spec merging" do
    test "merges a -spec into the immediately following function within 2-line slack" do
      chunks = ErlangChunker.chunk_file(fixture("mod_fake_backend.erl"))
      get_user = Enum.find(chunks, &(&1.symbol == "get_user/2"))

      assert get_user.start_line == 17
      assert get_user.end_line == 20
      assert get_user.text =~ "-spec get_user"
      assert get_user.text =~ "Backend:get_user"
    end

    test "merges positionally even when the spec name doesn't match the next function (ground-truth quirk)" do
      chunks = ErlangChunker.chunk_file(fixture("mod_orphan_spec.erl"))
      foo = Enum.find(chunks, &(&1.symbol == "foo/0"))

      # unused_callback_spec's -spec merges into foo/0 purely by line
      # adjacency, not because the names match.
      assert foo.start_line == 6
      assert foo.text =~ "unused_callback_spec"
    end

    test "leaves a trailing orphan -spec unmerged when nothing follows within slack" do
      chunks = ErlangChunker.chunk_file(fixture("mod_orphan_spec.erl"))

      assert Enum.any?(chunks, &(&1.symbol == "-spec" and &1.start_line == 11))
    end
  end

  describe "partial recovery" do
    test "tags every chunk partial when the file has an unresolved -include" do
      chunks = ErlangChunker.chunk_file(fixture("mod_broken_include.erl"))

      assert length(chunks) == 4
      assert Enum.all?(chunks, &(&1.warning == :partial))
    end

    test "still returns chunks for every form that did parse" do
      chunks = ErlangChunker.chunk_file(fixture("mod_broken_include.erl"))

      assert symbols(chunks) == ["-module", "-export", "works_fine/0", "also_fine/1"]
    end
  end

  describe "oversized-chunk splitting" do
    test "splits a >80-line function into overlapping windows, preserving its symbol" do
      chunks = ErlangChunker.chunk_file(fixture("mod_oversized.erl"))

      assert length(chunks) > 3
      big_chunks = Enum.filter(chunks, &(&1.symbol == "big/0"))
      assert length(big_chunks) == 2

      [first, second] = big_chunks
      assert first.end_line - first.start_line + 1 <= 60
      # consecutive windows overlap by 10 lines
      assert second.start_line == first.end_line - 9
    end
  end

  describe "fallback behavior" do
    test "falls back to line-window chunking when the file parses cleanly but yields no chunks" do
      chunks = ErlangChunker.chunk_file(fixture("empty_comment_only.hrl"))

      assert [%{kind: :text_window, warning: :failed}] = chunks
    end

    test "returns no chunks (no fallback) when the file can't be opened at all" do
      assert ErlangChunker.chunk_file(fixture("does_not_exist.erl")) == []
    end
  end
end
