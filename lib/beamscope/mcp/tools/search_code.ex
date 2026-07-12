defmodule Beamscope.MCP.Tools.SearchCode do
  @moduledoc """
  MCP tool: searches a repo for a natural-language or exact-name query,
  returning two separate result lists — `exact_matches` (a literal grep for
  identifier-like terms in the query, works with no extra dependencies) and
  `semantic_matches` (embedding search over the repo's chunks, requires the
  optional `bumblebee`/`nx`/`torchx` deps — see `Beamscope.Embeddings`).
  They're kept separate rather than blended into one ranking, since an
  exact match and a similarity score aren't the same kind of signal — grep
  reliably wins on exact-name queries where semantic search is only
  probabilistic. If the ML deps aren't installed, `semantic_matches` is
  empty and `semantic_search_unavailable` explains why, but `exact_matches`
  still works.
  """

  @behaviour Beamscope.MCP.Tool

  alias Beamscope.Repo

  @impl true
  def name, do: "search_code"

  @impl true
  def description,
    do:
      "Search a repo's code for a natural-language or exact-name query. Returns exact " <>
        "(literal/grep) matches and semantic (embedding) matches as separate lists."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "repo_path" => %{
          "type" => "string",
          "description" =>
            "Absolute or relative path to the repo to query (indexed/cached on first use)"
        },
        "query" => %{
          "type" => "string",
          "description" =>
            "Natural-language description of what to find (e.g. \"where is the user session validated\"), " <>
              "or an exact name (e.g. \"pop_messages\") — exact names are also matched literally"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of results per list to return (default 10)"
        }
      },
      "required" => ["repo_path", "query"]
    }
  end

  @impl true
  def call(%{"repo_path" => repo_path, "query" => query} = params) do
    limit = Map.get(params, "limit", 10)

    case Repo.search(repo_path, query, limit: limit) do
      {:ok,
       %{exact_matches: exact_matches, semantic_matches: semantic_matches, semantic_error: nil}} ->
        {:ok, %{query: query, exact_matches: exact_matches, semantic_matches: semantic_matches}}

      {:ok,
       %{
         exact_matches: exact_matches,
         semantic_matches: [],
         semantic_error: :embeddings_not_available
       }} ->
        {:ok,
         %{
           query: query,
           exact_matches: exact_matches,
           semantic_matches: [],
           semantic_search_unavailable: embeddings_not_available_message()
         }}

      {:ok, %{exact_matches: exact_matches, semantic_matches: [], semantic_error: reason}} ->
        {:ok,
         %{
           query: query,
           exact_matches: exact_matches,
           semantic_matches: [],
           semantic_search_error: inspect(reason)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embeddings_not_available_message do
    ~s|search_code's semantic matches require the optional bumblebee/nx/torchx dependencies | <>
      ~s|(exact_matches still work without them). Add {:bumblebee, "~> 0.7"}, {:nx, "~> 0.12"}, | <>
      ~s|{:torchx, "~> 0.12"} to your mix.exs deps and run mix deps.get.|
  end
end
