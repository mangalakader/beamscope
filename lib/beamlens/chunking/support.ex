defmodule Beamlens.Chunking.Support do
  @moduledoc """
  Line-extraction, sliding-window, and oversized-chunk-splitting helpers
  shared by the per-language chunkers. Mirrors chunker.py's `_slice_lines`,
  `chunk_by_lines`, and `_split_oversized_chunks` so chunk boundaries stay
  comparable to the original Python pipeline.
  """

  @window_lines 60
  @overlap_lines 10
  @max_chunk_lines 80
  @max_chunk_chars 3000

  @spec extract_text([String.t()], pos_integer(), pos_integer()) :: String.t()
  def extract_text(source_lines, start_line, end_line) do
    total = length(source_lines)
    clamped_end = min(end_line, total)
    count = max(clamped_end - start_line + 1, 0)

    source_lines
    |> Enum.slice(start_line - 1, count)
    |> Enum.join("\n")
  end

  @doc """
  Splits a chunk into a sliding window (default 60 lines/10-line overlap,
  shrinking further if any window exceeds the char budget) when it exceeds
  `:max_chunk_lines` or `:max_chunk_chars`, preserving the original symbol
  on every sub-chunk. Returns `[chunk]` unchanged otherwise.

  All thresholds are overridable via `opts` (`:max_chunk_lines`,
  `:max_chunk_chars`, `:window_lines`, `:overlap_lines`) — defaults match
  chunker.py's constants for parity with the original pipeline.
  """
  @spec split_if_oversized(map(), keyword()) :: [map()]
  def split_if_oversized(chunk, opts \\ [])

  def split_if_oversized(%{start_line: start_line, end_line: end_line, text: text} = chunk, opts) do
    max_chunk_lines = Keyword.get(opts, :max_chunk_lines, @max_chunk_lines)
    max_chunk_chars = Keyword.get(opts, :max_chunk_chars, @max_chunk_chars)
    window = Keyword.get(opts, :window_lines, @window_lines)
    overlap = Keyword.get(opts, :overlap_lines, @overlap_lines)
    line_count = end_line - start_line + 1

    if line_count <= max_chunk_lines and String.length(text) <= max_chunk_chars do
      [chunk]
    else
      text
      |> String.split("\n")
      |> sliding_windows(window, overlap, max_chunk_chars)
      |> Enum.map(fn {rel_start, rel_end, sub_text} ->
        %{
          chunk
          | start_line: start_line + rel_start,
            end_line: start_line + rel_end - 1,
            text: sub_text
        }
      end)
    end
  end

  @doc """
  Walks `lines` in a `window`-line sliding window with `overlap` lines of
  overlap between consecutive windows, shrinking any window whose joined
  text exceeds `max_chars`. Returns `{start_idx0, end_idx_exclusive, text}`
  triples (0-based, matching Python slice semantics), skipping
  whitespace-only windows.
  """
  @spec sliding_windows([String.t()], pos_integer(), non_neg_integer(), pos_integer()) ::
          [{non_neg_integer(), non_neg_integer(), String.t()}]
  def sliding_windows(lines, window, overlap, max_chars) do
    n = length(lines)
    do_sliding_windows(lines, 0, n, window, overlap, max_chars, [])
  end

  defp do_sliding_windows(_lines, i, n, _window, _overlap, _max_chars, acc) when n == 0 or i >= n,
    do: Enum.reverse(acc)

  defp do_sliding_windows(lines, i, n, window, overlap, max_chars, acc) do
    end_ = min(i + window, n)
    {end_, text} = shrink_to_budget(lines, i, end_, max_chars)
    acc = if String.trim(text) == "", do: acc, else: [{i, end_, text} | acc]

    if end_ >= n do
      Enum.reverse(acc)
    else
      next_i = end_ - min(overlap, end_ - i - 1)
      do_sliding_windows(lines, next_i, n, window, overlap, max_chars, acc)
    end
  end

  defp shrink_to_budget(lines, i, end_, max_chars) do
    text = lines |> Enum.slice(i, end_ - i) |> Enum.join("\n")

    if String.length(text) > max_chars and end_ > i + 1 do
      shrink_to_budget(lines, i, end_ - 1, max_chars)
    else
      {end_, text}
    end
  end
end
