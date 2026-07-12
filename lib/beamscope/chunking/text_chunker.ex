defmodule Beamscope.Chunking.TextChunker do
  @moduledoc """
  Shared line-window fallback used by both language chunkers when a source
  file cannot be parsed at all. Mirrors chunker.py's `chunk_by_lines`.
  """

  alias Beamscope.Chunking.Support

  @window_lines 60
  @overlap_lines 10
  @max_chars 3000

  @spec chunk(String.t(), keyword()) :: [map()]
  def chunk(path, opts \\ []) do
    window = Keyword.get(opts, :window_lines, @window_lines)
    overlap = Keyword.get(opts, :overlap_lines, @overlap_lines)
    max_chars = Keyword.get(opts, :max_chars, @max_chars)

    lines = path |> File.read!() |> String.split("\n")

    lines
    |> Support.sliding_windows(window, overlap, max_chars)
    |> Enum.map(fn {rel_start, rel_end, text} ->
      %{
        file_path: path,
        symbol: nil,
        start_line: rel_start + 1,
        end_line: rel_end,
        text: text,
        kind: :text_window,
        warning: :failed
      }
    end)
  end
end
