defmodule Beamlens.Chunking.ErlangChunker do
  @moduledoc """
  Chunks `.erl`/`.hrl` files by calling `:epp` in-process (no subprocess),
  so macros and includes are resolved exactly as the compiler would resolve
  them.

  Ported from `extract_chunks.erl` plus the chunk-assembly logic in
  `chunker.py` (spec merging, oversized-chunk splitting) in the original
  Python-orchestrated pipeline. Parsing and the file-ownership fix (forms
  belonging to an `-include`'d header are dropped rather than chunked
  under the including file — see `Beamlens.ErlangForms` for why)
  are shared with the call-graph extractor.

  Falls back to `TextChunker`'s line-window only when parsing succeeds but
  yields zero chunks (e.g. a header with no forms) — a genuinely fatal
  parse failure (the file can't even be opened) yields no chunks at all,
  matching chunker.py exactly: its line-window fallback is gated on the
  extractor's exit code being 0, which a fatal failure never is.
  """

  alias Beamlens.Chunking.{Support, TextChunker}
  alias Beamlens.ErlangForms

  @spec chunk_file(String.t(), keyword()) :: [map()]
  def chunk_file(path, opts \\ []) do
    include_dirs = Keyword.get(opts, :include_dirs, [])

    case ErlangForms.parse_owned_forms(path, include_dirs) do
      {:ok, own_forms, partial?} ->
        source_lines = path |> File.read!() |> String.split("\n")

        chunks =
          own_forms
          |> build_raw_chunks(path, source_lines)
          |> merge_specs_into_functions()
          |> Enum.flat_map(&Support.split_if_oversized(&1, opts))
          |> Enum.map(&maybe_tag_partial(&1, partial?))

        # Mirrors chunker.py: a *fatal* parse failure yields no chunks at
        # all (no fallback — see the {:error, _reason} clause below), but a
        # *clean* parse that simply had no functions/attributes to chunk
        # (e.g. a header with only comments) falls back to line windows so
        # the file is still searchable.
        case chunks do
          [] -> TextChunker.chunk(path, opts)
          chunks -> chunks
        end

      {:error, _reason} ->
        []
    end
  end

  defp build_raw_chunks(forms, path, source_lines) do
    Enum.flat_map(forms, fn
      {:function, line, name, arity, _clauses} = form ->
        end_line = max(line, ErlangForms.deep_max_line(form))

        [
          %{
            file_path: path,
            symbol: "#{name}/#{arity}",
            start_line: line,
            end_line: end_line,
            text: Support.extract_text(source_lines, line, end_line),
            kind: :function,
            warning: nil
          }
        ]

      {:attribute, line, name, _value} = form ->
        end_line = max(line, ErlangForms.deep_max_line(form))

        [
          %{
            file_path: path,
            symbol: "-#{name}",
            start_line: line,
            end_line: end_line,
            text: Support.extract_text(source_lines, line, end_line),
            kind: :attribute,
            warning: nil
          }
        ]

      _other ->
        []
    end)
  end

  # Mirrors chunker.py's _merge_specs_into_functions: a `-spec` chunk is
  # merged into whatever chunk comes next by start line, not the function
  # that actually matches its name/arity, as long as that next chunk isn't
  # itself another attribute and starts within 2 lines of the spec's end
  # (slack for a blank line between the spec's `.` and the function head).
  defp merge_specs_into_functions(chunks) do
    chunks
    |> Enum.sort_by(& &1.start_line)
    |> merge_sorted()
  end

  defp merge_sorted([spec, next | rest]) do
    if spec.symbol == "-spec" and not String.starts_with?(next.symbol, "-") and
         next.start_line <= spec.end_line + 2 do
      merged = %{
        next
        | start_line: spec.start_line,
          end_line: next.end_line,
          text: String.trim_trailing(spec.text) <> "\n" <> next.text
      }

      [merged | merge_sorted(rest)]
    else
      [spec | merge_sorted([next | rest])]
    end
  end

  defp merge_sorted(chunks), do: chunks

  defp maybe_tag_partial(chunk, false), do: chunk
  defp maybe_tag_partial(chunk, true), do: %{chunk | warning: :partial}
end
