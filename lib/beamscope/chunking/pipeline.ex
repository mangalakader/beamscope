defmodule Beamscope.Chunking.Pipeline do
  @moduledoc """
  Walks a repo and chunks every file concurrently via
  `Task.Supervisor.async_stream_nolink`, merging the per-file chunk lists
  into one combined list. Each file's parse (`:epp`/`Code.string_to_quoted`)
  is a pure, self-contained operation with no shared state, so files are
  trivially parallelizable — only the final merge step needs to wait for
  every task. Using the supervised, `nolink` variant (rather than plain
  `Task.async_stream`) means a file that raises an exception (not just one
  that times out) is isolated to that file's `:errors` entry instead of
  crashing the caller — which, for callers like `Beamscope.Search.Store`, is
  a singleton GenServer caching state for every repo ever queried.

  File discovery mirrors chunker.py's `walk_repo`/`CODE_EXTENSIONS`/
  `SKIP_DIRS` so the file set stays comparable to the original pipeline.

  Emits `:telemetry` events so callers can observe progress without the
  core pipeline doing any IO itself:

    * `[:beamscope, :chunk_repo, :start]` — measurements: `%{file_count}`;
      metadata: `%{repo_path}`
    * `[:beamscope, :chunk_repo, :file, :start | :stop | :exception]` —
      standard `:telemetry.span/3` events per file; `:stop` measurements
      include `:duration` (native time units) and metadata includes
      `%{file_path, chunk_count}`
    * `[:beamscope, :chunk_repo, :stop]` — measurements:
      `%{duration, total_chunks, total_errors}`; metadata: `%{repo_path}`

  See `Beamscope.Chunking.ProgressReporter` for an opt-in handler that
  prints a live progress line and summary from these events.
  """

  alias Beamscope.Chunking.{ElixirChunker, ErlangChunker, IncludePaths, TextChunker}

  @code_extensions %{
    ".erl" => :erlang,
    ".hrl" => :erlang,
    ".ex" => :elixir,
    ".exs" => :elixir
  }

  @text_extensions ~w(.md .rst .cfg .toml .yml .yaml .txt)

  @skip_dirs ~w(.git _build deps node_modules .elixir_ls _checkouts ebin priv/ssl .rebar3)

  @spec walk_repo(String.t()) :: [String.t()]
  def walk_repo(repo_path) do
    repo_path |> Path.expand() |> do_walk()
  end

  defp do_walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) ->
              if entry in @skip_dirs or String.starts_with?(entry, "."),
                do: [],
                else: do_walk(path)

            chunkable?(path) ->
              [path]

            true ->
              []
          end
        end)

      # Unreadable directory (permissions, dangling symlink, race with a
      # concurrent delete) — skip it rather than crashing the whole walk.
      {:error, _reason} ->
        []
    end
  end

  defp chunkable?(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.has_key?(@code_extensions, ext) or ext in @text_extensions
  end

  @doc """
  Chunks every discoverable file under `repo_path` concurrently, merging
  all per-file chunk lists into one combined list.

  Options:
    * `:max_concurrency` — files parsed in parallel (default:
      `System.schedulers_online()`; pass `1` to force sequential
      processing for comparison)
    * `:timeout` — per-file timeout in ms (default 30_000, matching
      chunker.py's SUBPROCESS_TIMEOUT_SECONDS)
    * `:max_chunk_lines`, `:max_chunk_chars`, `:window_lines`,
      `:overlap_lines` — forwarded to `Support.split_if_oversized/2` and
      `TextChunker.chunk/2` (module-level chunk-size controls)
    * `:include_dirs` — forwarded to `ErlangChunker.chunk_file/2`, merged
      with auto-discovered `_build/*/lib` dirs unless
      `:auto_discover_includes` is `false`
    * `:auto_discover_includes` — when true (default), scans
      `repo_path` for `_build/*/lib/<dep>/{include,ebin}` and wires them
      in for `-include_lib` resolution, mirroring chunker.py's
      `find_include_dirs`/`find_ebin_dirs` (see `IncludePaths`)

  Returns `%{chunks: [map()], errors: [{path, reason}]}` — a file that
  times out or crashes is recorded in `:errors` rather than failing the
  whole run.
  """
  @spec chunk_repo(String.t(), keyword()) :: %{chunks: [map()], errors: [{String.t(), term()}]}
  def chunk_repo(repo_path, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, 30_000)
    opts = maybe_discover_includes(repo_path, opts)
    files = walk_repo(repo_path)

    :telemetry.execute(
      [:beamscope, :chunk_repo, :start],
      %{file_count: length(files)},
      %{repo_path: repo_path}
    )

    start_time = System.monotonic_time()

    result =
      Beamscope.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        files,
        &chunk_file_traced(&1, opts),
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> merge_results()

    :telemetry.execute(
      [:beamscope, :chunk_repo, :stop],
      %{
        duration: System.monotonic_time() - start_time,
        total_chunks: length(result.chunks),
        total_errors: length(result.errors)
      },
      %{repo_path: repo_path}
    )

    result
  end

  defp chunk_file_traced(path, opts) do
    :telemetry.span(
      [:beamscope, :chunk_repo, :file],
      %{file_path: path},
      fn ->
        chunks = chunk_file(path, opts)
        {chunks, %{file_path: path, chunk_count: length(chunks)}}
      end
    )
  end

  defp maybe_discover_includes(repo_path, opts) do
    if Keyword.get(opts, :auto_discover_includes, true) do
      discovered_includes = IncludePaths.find_include_dirs(repo_path)
      ebin_dirs = repo_path |> IncludePaths.find_ebin_dirs() |> Enum.map(&to_charlist/1)
      :code.add_pathsz(ebin_dirs)

      Keyword.update(opts, :include_dirs, discovered_includes, &(&1 ++ discovered_includes))
    else
      opts
    end
  end

  defp merge_results(results) do
    {chunk_lists, errors} =
      Enum.reduce(results, {[], []}, fn
        {:ok, chunks}, {chunk_lists, errors} ->
          {[chunks | chunk_lists], errors}

        {:exit, {path, reason}}, {chunk_lists, errors} ->
          {chunk_lists, [{path, reason} | errors]}
      end)

    %{chunks: chunk_lists |> Enum.reverse() |> List.flatten(), errors: Enum.reverse(errors)}
  end

  defp chunk_file(path, opts) do
    ext = path |> Path.extname() |> String.downcase()

    case Map.get(@code_extensions, ext) do
      :erlang -> ErlangChunker.chunk_file(path, opts)
      :elixir -> ElixirChunker.chunk_file(path, opts)
      nil -> TextChunker.chunk(path, opts)
    end
  end
end
