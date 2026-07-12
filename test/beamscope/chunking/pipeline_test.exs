defmodule Beamscope.Chunking.PipelineTest do
  use ExUnit.Case, async: true

  alias Beamscope.Chunking.Pipeline

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamscope_chunk_pipeline_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "good.ex"), """
    defmodule Beamscope.ChunkPipelineFixture do
      def hello, do: :world
    end
    """)

    # A dangling symlink raises File.Error on read regardless of UID/CI —
    # unlike chmod 0o000, which root silently ignores.
    File.ln_s!(Path.join(dir, "does_not_exist"), Path.join(dir, "dangling.ex"))

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "a file that raises during chunking is isolated to :errors, not the whole run", %{dir: dir} do
    result = Pipeline.chunk_repo(dir)

    assert Enum.any?(result.chunks, &(&1.symbol =~ "hello"))
    assert [{path, _reason}] = result.errors
    assert path == Path.join(dir, "dangling.ex")
  end
end
