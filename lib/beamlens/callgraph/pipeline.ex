defmodule Beamlens.Callgraph.Pipeline do
  @moduledoc """
  Walks a repo and extracts call-graph defs/edges from every file
  concurrently via `Task.Supervisor.async_stream_nolink`, mirroring
  `Beamlens.Chunking.Pipeline.chunk_repo/2` (same file discovery,
  same concurrency model, same `:telemetry` events under a
  `[:beamlens, :callgraph_repo, ...]` prefix). Kept as a separate
  pipeline from chunking rather than folded into it, since defs/edges
  accumulate differently (into one shared graph) than chunks (into one
  flat list).
  """

  alias Beamlens.Callgraph.{Extractor, Graph}
  alias Beamlens.Chunking.Pipeline, as: ChunkingPipeline

  @spec extract_repo(String.t(), keyword()) :: %{
          defs: [map()],
          edges: [map()],
          errors: [{String.t(), term()}]
        }
  def extract_repo(repo_path, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, 30_000)
    files = repo_path |> ChunkingPipeline.walk_repo() |> Enum.filter(&code_file?/1)

    :telemetry.execute(
      [:beamlens, :callgraph_repo, :start],
      %{file_count: length(files)},
      %{repo_path: repo_path}
    )

    start_time = System.monotonic_time()

    result =
      Beamlens.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        files,
        &extract_file_traced(&1, opts),
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> merge_results()

    :telemetry.execute(
      [:beamlens, :callgraph_repo, :stop],
      %{
        duration: System.monotonic_time() - start_time,
        total_defs: length(result.defs),
        total_edges: length(result.edges),
        total_errors: length(result.errors)
      },
      %{repo_path: repo_path}
    )

    result
  end

  @spec build_graph(String.t(), keyword()) :: Elixir.Graph.t()
  def build_graph(repo_path, opts \\ []) do
    %{defs: defs, edges: edges} = extract_repo(repo_path, opts)
    Graph.build(defs, edges)
  end

  defp code_file?(path), do: Path.extname(path) in [".erl", ".hrl", ".ex", ".exs"]

  defp extract_file_traced(path, opts) do
    :telemetry.span(
      [:beamlens, :callgraph_repo, :file],
      %{file_path: path},
      fn ->
        {defs, edges} = Extractor.extract_from_file(path, opts)
        {{defs, edges}, %{file_path: path, def_count: length(defs), edge_count: length(edges)}}
      end
    )
  end

  defp merge_results(results) do
    {def_lists, edge_lists, errors} =
      Enum.reduce(results, {[], [], []}, fn
        {:ok, {defs, edges}}, {def_lists, edge_lists, errors} ->
          {[defs | def_lists], [edges | edge_lists], errors}

        {:exit, {path, reason}}, {def_lists, edge_lists, errors} ->
          {def_lists, edge_lists, [{path, reason} | errors]}
      end)

    %{
      defs: def_lists |> Enum.reverse() |> List.flatten(),
      edges: edge_lists |> Enum.reverse() |> List.flatten(),
      errors: Enum.reverse(errors)
    }
  end
end
