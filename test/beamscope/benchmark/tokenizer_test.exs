defmodule Beamscope.Benchmark.TokenizerTest do
  use ExUnit.Case, async: true

  alias Beamscope.Benchmark.Tokenizer

  test "counts real BPE tokens, matching real tiktoken cl100k_base on the same text" do
    # Cross-checked by hand against a real `tiktoken` cl100k_base run on
    # this exact string: 10 tokens.
    assert Tokenizer.count("hello world, this is a test of tokenization") == 10
  end

  test "empty string is zero tokens" do
    assert Tokenizer.count("") == 0
  end

  test "longer text produces more tokens than shorter text" do
    assert Tokenizer.count("a") <
             Tokenizer.count("a much longer sentence with many more words in it")
  end
end
