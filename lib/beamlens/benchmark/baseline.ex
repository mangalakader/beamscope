defmodule Beamlens.Benchmark.Baseline do
  @moduledoc """
  The "no beamlens" comparison point: a real grep-equivalent scan (find
  every file that literally contains any of the given `terms`) followed by
  a real full read of every matching file — the same methodology used for
  `docs/search-benchmark-2026-07.md`'s manual benchmark ("sizes are the
  actual bytes returned by each approach"), automated instead of run by
  hand. Uses `Beamlens.Chunking.Pipeline.walk_repo/1` for file enumeration,
  the same file-discovery logic beamlens itself uses for indexing, so the
  baseline stays scoped to what the tool itself considers "the repo's
  code."

  Reading is capped at `@max_bytes` total. Real incident that motivated
  this: on a large monorepo, an auto-discovered term that happened to be
  extremely common (a short, ubiquitous function name — see
  `Beamlens.Benchmark.TaskDiscovery`'s "?" unresolved-dispatch exclusion,
  which this cap backstops for any other equally-common *real* name)
  matched nearly the entire repo; accumulating and joining that much
  content once is already expensive, and `Beamlens.Benchmark.Runner`
  re-invokes this function on every `Benchee` timing iteration — repeated
  multi-hundred-MB allocations exhausted memory within seconds. `capped?:
  true` signals the reported bytes/tokens are a lower bound, not the true
  full count, when the limit is hit — this measures "grep would return an
  enormous, most-of-the-repo result," which is itself an honest finding,
  not a number to hide.
  """

  alias Beamlens.Chunking.Pipeline, as: ChunkingPipeline

  @max_bytes 10_000_000

  @doc """
  Real bytes of every file under `repo_path` that literally contains any
  of `terms`, capped at `max_bytes` total (default `@max_bytes`, see
  moduledoc — overridable mainly so tests can exercise the cap without a
  multi-megabyte fixture). Returns `%{bytes: 0, text: "", capped?: false}`
  for an empty term list — there's nothing to grep for (the honest
  baseline cost for a purely conceptual query with no exact name to
  search).
  """
  @spec measure(String.t(), [String.t()], pos_integer()) :: %{
          bytes: non_neg_integer(),
          text: String.t(),
          capped?: boolean()
        }
  def measure(repo_path, terms, max_bytes \\ @max_bytes)

  def measure(_repo_path, [], _max_bytes), do: %{bytes: 0, text: "", capped?: false}

  def measure(repo_path, terms, max_bytes) do
    matching_files =
      repo_path
      |> ChunkingPipeline.walk_repo()
      |> Enum.filter(&file_contains_any?(&1, terms))

    {contents, total_bytes, capped?} = read_up_to(matching_files, max_bytes)

    %{bytes: total_bytes, text: Enum.join(contents, "\n"), capped?: capped?}
  end

  defp read_up_to(paths, max_bytes) do
    {acc, total, capped?} =
      Enum.reduce_while(paths, {[], 0, false}, fn path, {acc, total, _capped?} ->
        if total >= max_bytes do
          {:halt, {acc, total, true}}
        else
          content = safe_read(path)
          {:cont, {[content | acc], total + byte_size(content), false}}
        end
      end)

    {Enum.reverse(acc), total, capped?}
  end

  defp file_contains_any?(path, terms) do
    case File.read(path) do
      {:ok, content} -> Enum.any?(terms, &String.contains?(content, &1))
      {:error, _reason} -> false
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end
end
