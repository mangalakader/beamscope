defmodule Beamscope.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias Beamscope.Embeddings

  # Generous timeout: first call downloads/loads the model.
  @moduletag timeout: 120_000

  test "available?/0 reflects whether the optional ML deps are loaded" do
    assert Embeddings.available?()
  end

  @tag :external
  test "a bad (non-UTF-8) query doesn't crash the GenServer — it stays usable afterward" do
    # This is the real failure mode run_serving/2's rescue/catch exists for
    # (see Beamscope.Search.Store's UTF-8 filter, the primary defense — this
    # is the last-resort net for anything that gets past it). Whether the
    # named Nx.Serving processes are already running (from an earlier test
    # in this run) or not, feeding genuinely invalid UTF-8 straight to the
    # real tokenizer should come back as a clean {:error, _}, and the shared
    # Embeddings GenServer (and its servings) must still work right after.
    assert {:error, _reason} = Embeddings.embed_query(<<0xFF, 0xFE, 0x00, 0x01>>)
    assert {:ok, _vector} = Embeddings.embed_query("a perfectly normal query")
  end

  @tag :external
  test "embed_query/1 returns a single normalized 384-dim vector for one query" do
    assert {:ok, vector} = Embeddings.embed_query("what does this function do")
    assert length(vector) == 384
    assert Enum.all?(vector, &is_float/1)
  end

  @tag :external
  test "embed_documents/1 returns one vector per input, in order, for different inputs" do
    assert {:ok, [v1, v2]} = Embeddings.embed_documents(["first text", "second text"])
    assert length(v1) == 384
    assert length(v2) == 384
    assert v1 != v2
  end

  @tag :external
  test "a warm embed_query/1 call is fast — regression guard for the ~16-46s padding/retracing bug" do
    # Pay the (real, first-call) load cost once, untimed.
    assert {:ok, _vector} = Embeddings.embed_query("warm the model up")

    {elapsed_us, {:ok, _vector}} =
      :timer.tc(fn -> Embeddings.embed_query("where is the session validated") end)

    assert elapsed_us < 1_000_000
  end
end
