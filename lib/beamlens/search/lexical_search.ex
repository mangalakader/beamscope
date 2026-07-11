defmodule Beamlens.Search.LexicalSearch do
  @moduledoc """
  Exact/literal-text search over a repo's files for identifier-like terms
  pulled out of a natural-language `search_code` query — an in-process grep
  (no subprocess), run alongside `Beamlens.Search.Store`'s embedding search
  rather than instead of it.

  Exists because semantic search alone loses to plain grep on every
  exact-name-style query tested in `docs/search-benchmark-2026-07.md`,
  across three independent codebases — "where is `pop_messages` defined"
  is an exact-match question, and probabilistic ranking is the wrong tool
  for a question that already has a literal string to match against.
  `Beamlens.Repo.search/3` returns this alongside (not blended into) the
  semantic results, since an exact match and a cosine-similarity score
  aren't the same kind of signal.
  """

  alias Beamlens.Chunking.Pipeline, as: ChunkingPipeline

  @doc """
  All literal matches across the repo for identifier-like terms in `query`
  — every file is scanned (no early cutoff), since capping the scan before
  ranking is exactly what let a real definition get buried behind
  less-relevant matches in practice; callers that want ranking-then-limit
  (e.g. `Beamlens.Repo.search/3`) apply `:limit` after sorting, not here.
  """
  @spec search(String.t(), String.t(), keyword()) :: [map()]
  def search(repo_path, query, _opts \\ []) do
    case extract_terms(query) do
      [] -> []
      terms -> repo_path |> ChunkingPipeline.walk_repo() |> Enum.flat_map(&grep_file(&1, terms))
    end
  end

  @doc "Pulls the terms worth grepping for out of a natural-language query. Exposed for testing."
  @spec extract_terms(String.t()) :: [String.t()]
  def extract_terms(query) do
    quoted = extract_quoted(query)

    bare =
      query
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&strip_punctuation/1)
      |> Enum.filter(&identifier_like?/1)

    (quoted ++ bare)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&expand_qualified/1)
    |> Enum.uniq()
  end

  # A qualified/arity-suffixed term ("mongoose_backend:call_tracked/4",
  # "Calendar.ISO.date_to_string") rarely appears verbatim at a real call
  # site or def line — also grep for the bare trailing identifier.
  defp expand_qualified(term) do
    bare =
      term
      |> String.replace(~r{/\d+$}, "")
      |> String.split(~r/[:.]/)
      |> List.last()

    Enum.uniq([term, bare])
  end

  # `Regex.scan/2` doesn't pad a trailing unmatched alternation group to a
  # fixed arity (a backtick match yields `[full, capture]`, a double-quote
  # match yields `[full, "", capture]`) — find whichever capture actually
  # matched instead of assuming a fixed shape.
  defp extract_quoted(query) do
    ~r/`([^`]+)`|"([^"]+)"/
    |> Regex.scan(query)
    |> Enum.map(fn [_full | captures] -> Enum.find(captures, &(&1 != "")) end)
  end

  # NOTE: `String.trim/2`'s second argument is an exact affix to strip, not
  # a character class — a regex is what actually removes a run of any of
  # these characters from either end.
  @punctuation ~r/^[.,:;!?()\[\]{}'"`]+|[.,:;!?()\[\]{}'"`]+$/
  defp strip_punctuation(word), do: Regex.replace(@punctuation, word, "")

  # A bare (unquoted) word is worth grepping for only if it looks like a
  # code identifier rather than an English word: snake_case, dotted
  # (Module.fun), colon-qualified (mod:fun), arity-suffixed (name/2), or
  # camelCase/PascalCase. Explicitly quoted/backticked terms skip this
  # check entirely — quoting is already a strong signal of intent.
  defp identifier_like?(term) do
    String.length(term) > 2 and
      (String.contains?(term, "_") or String.contains?(term, ".") or
         String.contains?(term, ":") or String.contains?(term, "/") or camel_case?(term))
  end

  defp camel_case?(term), do: String.match?(term, ~r/[a-z][A-Z]/)

  defp grep_file(path, terms) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Enum.any?(terms, &String.contains?(line, &1)) end)
        |> Enum.map(fn {line, n} -> %{file_path: path, line: n, text: String.trim(line)} end)

      # Unreadable file (permissions, dangling symlink, race with a
      # concurrent delete) — skip it rather than crashing the search.
      {:error, _reason} ->
        []
    end
  end
end
