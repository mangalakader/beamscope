defmodule Beamlens.Search.Store do
  @moduledoc """
  Per-repo semantic search index: chunks a repo (via
  `Beamlens.Chunking.Pipeline`), embeds each chunk (via
  `Beamlens.Embeddings`), and persists `{key, vector, metadata}` rows to a
  DETS table at `<repo_path>/.beamlens/search.dets` — a build artifact of
  the target repo, parallel to `_build/`, meant to be gitignored there.

  DETS is the durable store; like `Beamlens.Callgraph.Store`, the built
  index also lives in this GenServer's in-memory state as a plain list, so
  repeated searches are in-memory scans rather than repeated disk reads.
  DETS exists so a server restart doesn't require re-embedding an entire
  repo — `get_or_build/2` opens an existing table if one is already on
  disk instead of rebuilding from scratch.

  Search is brute-force cosine similarity over the in-memory vector list.
  Realistic scale here is tens of thousands of vectors per repo, well
  within what a linear scan handles in well under a second — no ANN index
  needed.

  Returns `{:error, :embeddings_not_available}` from any operation that
  needs to embed text if the optional `bumblebee`/`nx`/`torchx` deps
  (see `Beamlens.Embeddings`) aren't installed.
  """

  use GenServer

  require Logger

  alias Beamlens.Chunking.Pipeline, as: ChunkingPipeline
  alias Beamlens.Embeddings

  @type repo_path :: String.t()

  @batch_size 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Ensures `repo_path` has a built index, opening an existing on-disk DETS
  table if present or building fresh otherwise. Returns `:ok`, or
  `{:error, :embeddings_not_available}` if the optional ML deps aren't
  installed.
  """
  @spec get_or_build(repo_path(), keyword()) :: :ok | {:error, term()}
  def get_or_build(repo_path, opts \\ []) do
    GenServer.call(__MODULE__, {:get_or_build, repo_path, opts}, :infinity)
  end

  @doc "Forces a rebuild of the index for `repo_path`, discarding any cached or on-disk version."
  @spec reindex(repo_path(), keyword()) :: :ok | {:error, term()}
  def reindex(repo_path, opts \\ []) do
    GenServer.call(__MODULE__, {:reindex, repo_path, opts}, :infinity)
  end

  @doc "Returns whether `repo_path` has a cached index, without building one."
  @spec indexed?(repo_path()) :: boolean()
  def indexed?(repo_path) do
    GenServer.call(__MODULE__, {:indexed?, repo_path})
  end

  @doc """
  Embeds `query` and returns the top-K most similar chunks (default 10,
  override via `:limit`) for `repo_path`, building the index first if
  necessary. Each result is `%{file_path:, symbol:, start_line:, end_line:,
  kind:, score:}`.
  """
  @spec search(repo_path(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(repo_path, query, opts \\ []) do
    GenServer.call(__MODULE__, {:search, repo_path, query, opts}, :infinity)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_or_build, repo_path, opts}, _from, state) do
    case ensure_built(repo_path, opts, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reindex, repo_path, opts}, _from, state) do
    state = close_and_forget(repo_path, state)
    File.rm(dets_path_for(repo_path))

    case do_build(repo_path, opts, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:indexed?, repo_path}, _from, state) do
    {:reply, Map.has_key?(state, repo_path), state}
  end

  def handle_call({:search, repo_path, query, opts}, _from, state) do
    case ensure_built(repo_path, [], state) do
      {:ok, new_state} ->
        %{vectors: vectors} = Map.fetch!(new_state, repo_path)

        case Embeddings.embed_query(query) do
          {:ok, query_vector} ->
            limit = Keyword.get(opts, :limit, 10)
            {:reply, {:ok, top_k(vectors, query_vector, limit)}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state, fn {_repo_path, %{table: table}} -> :dets.close(table) end)
    :ok
  end

  defp ensure_built(repo_path, opts, state) do
    case Map.fetch(state, repo_path) do
      {:ok, _entry} -> {:ok, state}
      :error -> do_build(repo_path, opts, state)
    end
  end

  defp do_build(repo_path, opts, state) do
    if Embeddings.available?() do
      dets_path = dets_path_for(repo_path)
      File.mkdir_p!(Path.dirname(dets_path))

      {:ok, table} =
        :dets.open_file(table_name_for(repo_path), file: to_charlist(dets_path), type: :set)

      vectors =
        case :dets.info(table, :size) do
          0 -> build_and_persist(repo_path, table, opts)
          _existing -> :dets.foldl(fn row, acc -> [row | acc] end, [], table)
        end

      {:ok, Map.put(state, repo_path, %{table: table, vectors: vectors})}
    else
      {:error, :embeddings_not_available}
    end
  end

  defp build_and_persist(repo_path, table, opts) do
    %{chunks: chunks} = ChunkingPipeline.chunk_repo(repo_path, opts)
    {valid_chunks, invalid_chunks} = Enum.split_with(chunks, &String.valid?(&1.text))

    if invalid_chunks != [] do
      Logger.warning(
        "beamlens: skipping #{length(invalid_chunks)} chunk(s) with invalid UTF-8 text while indexing #{repo_path}"
      )
    end

    valid_chunks
    |> Enum.chunk_every(@batch_size)
    |> Enum.flat_map(&embed_and_insert_batch(&1, table))
  end

  defp embed_and_insert_batch(batch, table) do
    texts = Enum.map(batch, & &1.text)

    case Embeddings.embed_documents(texts) do
      {:ok, vectors} ->
        batch
        |> Enum.zip(vectors)
        |> Enum.map(fn {chunk, vector} ->
          key = "#{chunk.file_path}:#{chunk.start_line}"
          metadata = Map.take(chunk, [:file_path, :symbol, :start_line, :end_line, :kind])
          row = {key, vector, metadata}
          :dets.insert(table, row)
          row
        end)

      {:error, _reason} ->
        []
    end
  end

  defp close_and_forget(repo_path, state) do
    case Map.pop(state, repo_path) do
      {nil, state} ->
        state

      {%{table: table}, state} ->
        :dets.close(table)
        state
    end
  end

  defp top_k(vectors, query_vector, limit) do
    vectors
    |> Enum.map(fn {_key, vector, metadata} ->
      {cosine_similarity(vector, query_vector), metadata}
    end)
    |> Enum.sort_by(fn {score, _metadata} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {score, metadata} -> Map.put(metadata, :score, score) end)
  end

  defp cosine_similarity(a, b) do
    dot = a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end

  defp dets_path_for(repo_path), do: Path.join([repo_path, ".beamlens", "search.dets"])
  defp table_name_for(repo_path), do: :"beamlens_search_#{:erlang.phash2(repo_path)}"
end
