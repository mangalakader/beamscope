defmodule Beamlens.Chunking.ElixirChunker do
  @moduledoc """
  Chunks `.ex`/`.exs` files by walking the quoted AST for
  `defmodule`/`def`/`defmacro` boundaries, using `Code.string_to_quoted/2`
  in-process (no subprocess).

  Ported from `extract_chunks.exs` in the original Python-orchestrated
  pipeline, with two deliberate fixes over the original: nested
  `defmodule` names are qualified with their outer module path (the
  original discards the outer context, so a `Nested` module inside
  `Foo.Bar` gets chunked under the bare name "Nested" instead of
  "Foo.Bar.Nested"), and `when`-guarded def/defp/defmacro/defmacrop heads
  are unwrapped before extracting the function name and end line (the
  original's `{name, _, _args}` match against the raw head binds `name` to
  the literal atom `:when` for any guarded clause, and its end-line scan
  only covers the trailing keyword list, not the guard). Module chunks
  themselves are still skipped, and symbols still omit arity, matching the
  original — see docs/phase0-parity-report.md for the full comparison.
  """

  alias Beamlens.Chunking.{Support, TextChunker}

  @spec chunk_file(String.t(), keyword()) :: [map()]
  def chunk_file(path, opts \\ []) do
    source = File.read!(path)

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        source_lines = String.split(source, "\n")

        chunks =
          ast
          |> top_level_forms()
          |> Enum.flat_map(&walk(&1, path, source_lines, [], opts))

        # Mirrors chunker.py: a *fatal* parse failure yields no chunks at
        # all (no fallback — see the {:error, _reason} clause below), but a
        # *clean* parse with nothing to chunk (e.g. a script with no
        # defmodule/def) falls back to line windows so the file is still
        # searchable. Note this contradicts the original README's claim
        # that [warn:failed] falls back to line-window chunking — the
        # actual chunker.py code never reaches that fallback on a genuine
        # syntax error (its `if not chunks and returncode == 0` guard
        # excludes the returncode != 0 case), so this fixes what looks
        # like a latent bug/doc mismatch in the original rather than
        # replicating it.
        case chunks do
          [] -> TextChunker.chunk(path, opts)
          chunks -> chunks
        end

      {:error, _reason} ->
        []
    end
  end

  defp top_level_forms({:__block__, _meta, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp walk(
         {:defmodule, _meta, [{:__aliases__, _, mod_parts}, module_opts]},
         path,
         source_lines,
         module_path,
         opts
       ) do
    new_path = module_path ++ mod_parts

    module_opts
    |> Keyword.get(:do)
    |> top_level_forms()
    |> Enum.flat_map(&walk(&1, path, source_lines, new_path, opts))
  end

  defp walk({def_kind, meta, [head | rest]}, path, source_lines, module_path, opts)
       when def_kind in [:def, :defp, :defmacro, :defmacrop] do
    name = function_name(head)
    start_line = meta[:line]
    end_line = max(start_line, max_line({head, rest}))
    qualified_module = Enum.join(module_path, ".")

    chunk = %{
      file_path: path,
      symbol: "#{qualified_module}.#{name} (#{def_kind})",
      start_line: start_line,
      end_line: end_line,
      text: Support.extract_text(source_lines, start_line, end_line),
      kind: kind_for(def_kind),
      warning: nil
    }

    Support.split_if_oversized(chunk, opts)
  end

  defp walk(_other, _path, _source_lines, _module_path, _opts), do: []

  defp kind_for(kind) when kind in [:def, :defp], do: :function
  defp kind_for(kind) when kind in [:defmacro, :defmacrop], do: :macro

  defp function_name({:when, _meta, [inner_head, _guard]}), do: function_name(inner_head)
  defp function_name({name, _meta, _args}) when is_atom(name), do: name

  # Macro-generated name (e.g. `def unquote(name)(...)`) — can't be
  # statically resolved to an atom.
  defp function_name(_other), do: :"?"

  defp max_line(ast) do
    {_ast, max_seen} =
      Macro.prewalk(ast, 0, fn
        {_, meta, _} = node, acc when is_list(meta) ->
          {node, max(acc, Keyword.get(meta, :line, 0))}

        node, acc ->
          {node, acc}
      end)

    max_seen
  end
end
