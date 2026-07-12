defmodule Beamscope.Callgraph.Store do
  @moduledoc """
  Caches built call graphs per repo path so repeated queries (e.g. from MCP
  tool calls) don't re-walk and re-parse the whole repo on every call.

  Building a graph for a large repo takes real wall-clock time (seconds),
  so the first call for a given path pays that cost and every subsequent
  call for the same path is an in-memory lookup, until `reindex/2` is
  called explicitly.

  Also persists the built graph to `<repo_path>/.beamscope/callgraph.json`
  (`Graph.to_node_link_json/1`) so a server restart reloads it from disk
  instead of re-parsing the whole repo from source. Writes go to a
  `.tmp.<unique>` file first, renamed into place only once fully written —
  a crash mid-write leaves the last-known-good real file untouched rather
  than corrupting it.
  """

  use GenServer

  require Logger

  alias Beamscope.Callgraph.{Graph, Pipeline}

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
      {:ok, graph} ->
        {:reply, graph, state}

      :error ->
        case load_persisted(repo_path) do
          {:ok, graph} -> {:reply, graph, Map.put(state, repo_path, graph)}
          :error -> build_and_cache(repo_path, opts, state)
        end
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
    persist(repo_path, graph)
    {:reply, graph, Map.put(state, repo_path, graph)}
  end

  defp load_persisted(repo_path) do
    path = callgraph_path_for(repo_path)

    with true <- File.exists?(path),
         {:ok, json} <- File.read(path),
         {:ok, graph} <- safe_decode(json) do
      {:ok, graph}
    else
      _ -> :error
    end
  end

  defp safe_decode(json) do
    {:ok, Graph.from_node_link_json(json)}
  rescue
    error ->
      Logger.warning(
        "beamscope: ignoring unreadable persisted call graph at #{Exception.message(error)}"
      )

      :error
  end

  defp persist(repo_path, graph) do
    path = callgraph_path_for(repo_path)
    File.mkdir_p!(Path.dirname(path))
    cleanup_stray_tmp_files(path)

    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"
    File.write!(tmp_path, Graph.to_node_link_json(graph))
    File.rename!(tmp_path, path)
  rescue
    error ->
      Logger.warning(
        "beamscope: failed to persist call graph for #{repo_path}: #{Exception.message(error)}"
      )
  end

  defp cleanup_stray_tmp_files(path) do
    dir = Path.dirname(path)
    base = Path.basename(path)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "#{base}.tmp."))
        |> Enum.each(&File.rm(Path.join(dir, &1)))

      {:error, _reason} ->
        :ok
    end
  end

  defp callgraph_path_for(repo_path), do: Path.join([repo_path, ".beamscope", "callgraph.json"])
end
