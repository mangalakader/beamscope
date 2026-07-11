defmodule Beamlens.Callgraph.Store do
  @moduledoc """
  Caches built call graphs per repo path so repeated queries (e.g. from MCP
  tool calls) don't re-walk and re-parse the whole repo on every call.

  Building a graph for a large repo takes real wall-clock time (seconds),
  so the first call for a given path pays that cost and every subsequent
  call for the same path is an in-memory lookup, until `reindex/2` is
  called explicitly.
  """

  use GenServer

  alias Beamlens.Callgraph.Pipeline

  @type repo_path :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns the cached graph for `repo_path`, building and caching it first
  if this is the first request for that path.
  """
  @spec get_or_build(repo_path(), keyword()) :: Elixir.Graph.t()
  def get_or_build(repo_path, opts \\ []) do
    GenServer.call(__MODULE__, {:get_or_build, repo_path, opts}, :infinity)
  end

  @doc "Forces a rebuild of the graph for `repo_path`, replacing any cached version."
  @spec reindex(repo_path(), keyword()) :: Elixir.Graph.t()
  def reindex(repo_path, opts \\ []) do
    GenServer.call(__MODULE__, {:reindex, repo_path, opts}, :infinity)
  end

  @doc "Returns whether `repo_path` has a cached graph, without building one."
  @spec indexed?(repo_path()) :: boolean()
  def indexed?(repo_path) do
    GenServer.call(__MODULE__, {:indexed?, repo_path})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_or_build, repo_path, opts}, _from, state) do
    case Map.fetch(state, repo_path) do
      {:ok, graph} -> {:reply, graph, state}
      :error -> build_and_cache(repo_path, opts, state)
    end
  end

  def handle_call({:reindex, repo_path, opts}, _from, state) do
    build_and_cache(repo_path, opts, state)
  end

  def handle_call({:indexed?, repo_path}, _from, state) do
    {:reply, Map.has_key?(state, repo_path), state}
  end

  defp build_and_cache(repo_path, opts, state) do
    graph = Pipeline.build_graph(repo_path, opts)
    {:reply, graph, Map.put(state, repo_path, graph)}
  end
end
