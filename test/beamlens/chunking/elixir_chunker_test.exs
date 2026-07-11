defmodule Beamlens.Chunking.ElixirChunkerTest do
  use ExUnit.Case, async: true

  alias Beamlens.Chunking.ElixirChunker

  @fixtures Path.join([File.cwd!(), "priv", "fixtures"])

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "def/defp/defmacro extraction" do
    test "emits Module.name (def_kind) symbols, no arity, no module chunks" do
      chunks = ElixirChunker.chunk_file(fixture("fake_session.ex"))

      assert Enum.map(chunks, & &1.symbol) == [
               "Beamlens.FakeSession.resume (def)",
               "Beamlens.FakeSession.verify (defp)",
               "Beamlens.FakeSession.close (def)",
               "Beamlens.FakeSession.Nested.ping (def)"
             ]

      refute Enum.any?(chunks, &(&1.kind == :module))
    end

    test "qualifies a nested defmodule with its outer module path (deliberate fix)" do
      chunks = ElixirChunker.chunk_file(fixture("fake_session.ex"))
      ping = Enum.find(chunks, &String.contains?(&1.symbol, "ping"))

      assert ping.symbol == "Beamlens.FakeSession.Nested.ping (def)"
    end

    test "every chunk carries the source file_path" do
      chunks = ElixirChunker.chunk_file(fixture("fake_session.ex"))

      assert Enum.all?(chunks, &(&1.file_path == fixture("fake_session.ex")))
    end
  end

  describe "guard-clause handling (deliberate fix)" do
    test "unwraps a `when` guard so the real function name is used, not the atom :when" do
      chunks = ElixirChunker.chunk_file(fixture("fake_session.ex"))

      assert Enum.any?(chunks, &(&1.symbol == "Beamlens.FakeSession.verify (defp)"))
      refute Enum.any?(chunks, &String.contains?(&1.symbol, "when"))
    end
  end

  describe "fallback behavior" do
    test "falls back to line-window chunking when the file parses cleanly but yields no chunks" do
      chunks = ElixirChunker.chunk_file(fixture("no_defs.ex"))

      assert [%{kind: :text_window, warning: :failed}] = chunks
    end

    test "returns no chunks (no fallback) on a genuine syntax error" do
      assert ElixirChunker.chunk_file(fixture("broken_syntax.ex")) == []
    end

    test "a macro-generated def name (`def unquote(name)(...)`) doesn't crash the whole file" do
      chunks = ElixirChunker.chunk_file(fixture("unquoted_def_name.ex"))
      symbols = Enum.map(chunks, & &1.symbol)

      assert "Beamlens.FakeGenerated.normal_fun (def)" in symbols
      assert "Beamlens.FakeGenerated.? (def)" in symbols
    end
  end
end
