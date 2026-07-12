defmodule Beamlens.Repo do
  @moduledoc """
  Unified per-repo entry point over call-graph navigation and semantic
  search — the single interface MCP tools (and any other caller) should
  use rather than reaching into `Beamlens.Callgraph.Store` or
  `Beamlens.Search.Store` directly. Both stores already cache/persist per
  `repo_path` on their own; this module adds no state of its own, just one
  API surface over both.
  """

  alias Beamlens.Callgraph.{Graph, Store}
  alias Beamlens.Search.LexicalSearch
  alias Beamlens.Search.Store, as: SearchStore

  @type repo_path :: String.t()

  @doc """
  Every function that calls `module:function`, each enriched with its
  definition location (`file_path`/`start_line`/`end_line`) when known —
  see `Beamlens.Callgraph.Graph.callers_with_locations/2`.
  """
  @spec callers(repo_path(), String.t(), String.t()) ::
          {:ok, %{qualified_name: String.t(), callers: [map()]}} | {:error, String.t()}
  def callers(repo_path, module, function) do
    with :ok <- validate_repo_path(repo_path) do
      graph = Store.get_or_build(repo_path)
      qualified = Graph.qualified_name(module, function)
      {:ok, %{qualified_name: qualified, callers: Graph.callers_with_locations(graph, qualified)}}
    end
  end

  @doc """
  Every function `module:function` calls, each enriched with its definition
  location like `callers/3`.
  """
  @spec callees(repo_path(), String.t(), String.t()) ::
          {:ok, %{qualified_name: String.t(), callees: [map()]}} | {:error, String.t()}
  def callees(repo_path, module, function) do
    with :ok <- validate_repo_path(repo_path) do
      graph = Store.get_or_build(repo_path)
      qualified = Graph.qualified_name(module, function)
      {:ok, %{qualified_name: qualified, callees: Graph.callees_with_locations(graph, qualified)}}
    end
  end

  @doc """
  Shortest call path between two functions, if one exists, each hop
  enriched with its definition location like `callers/3`/`callees/3`.
  """
  @spec call_path(repo_path(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{from: String.t(), to: String.t(), path: [map()] | nil}}
          | {:error, String.t()}
  def call_path(repo_path, from_module, from_function, to_module, to_function) do
    with :ok <- validate_repo_path(repo_path) do
      from = Graph.qualified_name(from_module, from_function)
      to = Graph.qualified_name(to_module, to_function)
      graph = Store.get_or_build(repo_path)
      {:ok, %{from: from, to: to, path: Graph.shortest_path_with_locations(graph, from, to)}}
    end
  end

  @doc """
  Two independent kinds of results for a natural-language or exact-name
  `query`: `exact_matches` (a literal, in-process grep for identifier-like
  terms in the query — see `Beamlens.Search.LexicalSearch`, works with no
  ML deps installed) and `semantic_matches` (top-K similar chunks via
  `Beamlens.Search.Store.search/3`). Returned as two separate lists rather
  than one blended ranking, since an exact match and a cosine-similarity
  score aren't the same kind of signal. `semantic_error` is set (and
  `semantic_matches` is `[]`) when the embedding side fails or the optional
  ML deps aren't installed — that no longer fails the whole call.

  `exact_matches` is ranked using the call graph beamlens already builds: a
  match whose line is a known function's definition line is tagged
  `match_kind: :definition` and sorted ahead of everything else (tagged
  `:reference` — call sites, specs, comments, unrelated same-name hits in
  other files), *then* capped at `:limit`. Ranking before capping matters —
  scanning the whole repo but capping before ranking is exactly how a real
  definition previously got crowded out by less-relevant matches that
  happened to come first in file-walk order.
  """
  @spec search(repo_path(), String.t(), keyword()) ::
          {:ok,
           %{
             exact_matches: [map()],
             semantic_matches: [map()],
             semantic_error: term() | nil
           }}
          | {:error, String.t()}
  def search(repo_path, query, opts \\ []) do
    with :ok <- validate_repo_path(repo_path) do
      limit = Keyword.get(opts, :limit, 10)
      graph = Store.get_or_build(repo_path)
      terms = LexicalSearch.extract_terms(query)

      exact_matches =
        repo_path
        |> LexicalSearch.search(query, opts)
        |> rank_exact_matches(graph, terms)
        |> Enum.take(limit)

      {semantic_matches, semantic_error} =
        case SearchStore.search(repo_path, query, opts) do
          {:ok, results} -> {results, nil}
          {:error, reason} -> {[], reason}
        end

      {:ok,
       %{
         exact_matches: exact_matches,
         semantic_matches: semantic_matches,
         semantic_error: semantic_error
       }}
    end
  end

  defp rank_exact_matches(matches, graph, terms) do
    defs = Graph.defs(graph)

    matches
    |> Enum.map(fn match ->
      kind = if definition_match?(match, defs, terms), do: :definition, else: :reference
      Map.put(match, :match_kind, kind)
    end)
    |> Enum.sort_by(fn %{match_kind: kind} -> if kind == :definition, do: 0, else: 1 end)
  end

  defp definition_match?(%{file_path: file_path, line: line}, defs, terms) do
    Enum.any?(defs, fn d ->
      d.file_path == file_path and d.start_line == line and def_name_matches?(d, terms)
    end)
  end

  defp def_name_matches?(%{qualified_name: qualified_name}, terms) do
    bare_name = qualified_name |> String.split(":") |> List.last()
    bare_name in terms
  end

  @doc """
  Rebuilds both the call graph and, if the optional embedding deps are
  installed, the search index for `repo_path`.
  """
  @spec reindex(repo_path(), keyword()) :: :ok | {:error, String.t()}
  def reindex(repo_path, opts \\ []) do
    with :ok <- validate_repo_path(repo_path) do
      Store.reindex(repo_path, opts)
      if Beamlens.Embeddings.available?(), do: SearchStore.reindex(repo_path, opts)
      :ok
    end
  end

  @doc "Whether `repo_path` has a cached call graph."
  @spec indexed?(repo_path()) :: boolean()
  def indexed?(repo_path), do: Store.indexed?(repo_path)

  # Every builder here (`Callgraph.Store`/`Search.Store`) is a singleton
  # GenServer caching state for every repo_path ever queried; letting a
  # missing/non-directory path reach `File.ls!`/`:epp` deep inside a build
  # would crash that shared process and wipe every other repo's cache. Catch
  # it here, before either Store is ever called.
  defp validate_repo_path(repo_path) do
    if File.dir?(repo_path) do
      :ok
    else
      {:error, "repo_path does not exist or is not a directory: #{repo_path}"}
    end
  end
end
