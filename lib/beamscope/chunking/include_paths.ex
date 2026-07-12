defmodule Beamscope.Chunking.IncludePaths do
  @moduledoc """
  Discovers rebar3 `_build/*/lib` include/ebin directories so `:epp` can
  resolve `-include_lib` for third-party deps. Mirrors chunker.py's
  `find_include_dirs`/`find_ebin_dirs`/`_find_build_lib_dirs`, which the
  original pipeline relies on for every configured repo (see repos.json's
  `erlang_include_paths: ["_build/default/lib"]`).
  """

  @spec find_build_lib_dirs(String.t()) :: [String.t()]
  def find_build_lib_dirs(repo_root) do
    args = [
      repo_root,
      "-type",
      "d",
      "-path",
      "*/_build/*/lib",
      "-not",
      "-path",
      "*/_build/*/lib/*/*"
    ]

    case System.cmd("find", args) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  end

  @doc "Include dirs to pass to :epp's {includes, ...} option for -include_lib resolution."
  @spec find_include_dirs(String.t()) :: [String.t()]
  def find_include_dirs(repo_root) do
    repo_root
    |> find_build_lib_dirs()
    |> Enum.flat_map(fn lib_dir -> [lib_dir | dep_subdirs(lib_dir, "include")] end)
  end

  @doc "Dep ebin dirs to add to the code path so :code.lib_dir/1 resolves app names for -include_lib."
  @spec find_ebin_dirs(String.t()) :: [String.t()]
  def find_ebin_dirs(repo_root) do
    repo_root
    |> find_build_lib_dirs()
    |> Enum.flat_map(&dep_subdirs(&1, "ebin"))
  end

  defp dep_subdirs(lib_dir, subdir) do
    case File.ls(lib_dir) do
      {:ok, deps} ->
        deps
        |> Enum.map(&Path.join([lib_dir, &1, subdir]))
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end
end
