defmodule Beamlens.Chunking.SupportTest do
  use ExUnit.Case, async: true

  alias Beamlens.Chunking.Support

  describe "extract_text/3" do
    test "slices an inclusive 1-indexed line range" do
      lines = ["one", "two", "three", "four"]

      assert Support.extract_text(lines, 2, 3) == "two\nthree"
    end

    test "clamps end_line past the end of the file" do
      lines = ["one", "two"]

      assert Support.extract_text(lines, 1, 100) == "one\ntwo"
    end
  end

  describe "split_if_oversized/2" do
    test "leaves a chunk under both thresholds unchanged" do
      chunk = %{symbol: "f/1", start_line: 1, end_line: 5, text: "a\nb\nc\nd\ne"}

      assert Support.split_if_oversized(chunk) == [chunk]
    end

    test "splits a chunk exceeding max_chunk_lines into overlapping windows with the same symbol" do
      lines = for i <- 1..100, do: "line#{i}"
      text = Enum.join(lines, "\n")
      chunk = %{symbol: "big/0", start_line: 10, end_line: 109, text: text}

      [first, second] = Support.split_if_oversized(chunk, window_lines: 60, overlap_lines: 10)

      assert first.symbol == "big/0"
      assert second.symbol == "big/0"
      assert first.start_line == 10
      assert first.end_line == 69
      # 10-line overlap between consecutive windows
      assert second.start_line == first.end_line - 9
      assert second.end_line == 109
    end

    test "splits a chunk exceeding max_chunk_chars even when under the line threshold" do
      # 10 lines of 500 chars each (5000 total) — enough lines that the
      # char-budget shrink loop has room to cut a smaller window, unlike a
      # single massive line with no newline to split on.
      lines = for _ <- 1..10, do: String.duplicate("x", 500)
      chunk = %{symbol: "wide/0", start_line: 1, end_line: 10, text: Enum.join(lines, "\n")}

      result = Support.split_if_oversized(chunk, max_chunk_chars: 3000)

      assert length(result) > 1
      assert Enum.all?(result, &(String.length(&1.text) <= 3000))
    end

    test "respects overridable max_chunk_lines" do
      lines = for i <- 1..30, do: "line#{i}"
      chunk = %{symbol: "f/0", start_line: 1, end_line: 30, text: Enum.join(lines, "\n")}

      assert [_single] = Support.split_if_oversized(chunk)

      assert [_a, _b | _] =
               Support.split_if_oversized(chunk,
                 max_chunk_lines: 10,
                 window_lines: 10,
                 overlap_lines: 0
               )
    end
  end

  describe "sliding_windows/4" do
    test "skips whitespace-only windows" do
      lines = ["", "   ", ""]

      assert Support.sliding_windows(lines, 60, 10, 3000) == []
    end

    test "returns nothing for an empty line list" do
      assert Support.sliding_windows([], 60, 10, 3000) == []
    end
  end
end
