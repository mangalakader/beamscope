defmodule Beamscope.Benchmark.Tokenizer do
  @moduledoc """
  Real BPE token counts, natively in Elixir — no Python/`tiktoken` venv.

  Uses a vendored `cl100k_base`-equivalent tokenizer
  (`priv/tokenizer/cl100k_base.tokenizer.json`, a conversion published at
  the `Xenova/gpt-3.5-turbo` HF Hub repo) via the `tokenizers` Hex package
  (Rust-NIF bindings to HuggingFace's `tokenizers` crate — already resolved
  in this project's dependency tree via `bumblebee`, added here as an
  explicit, non-optional dependency since the benchmark tool needs it
  independent of the optional ML stack). Cross-checked against real
  `tiktoken`'s `cl100k_base` encoding on sample text: identical counts.

  Loaded once per BEAM instance via `:persistent_term` — no network access
  at benchmark-run time, and no per-call reparse of the ~4MB vocab file.
  """

  @persistent_term_key {__MODULE__, :tokenizer}

  @doc "Real token count for `text` using the vendored cl100k_base-equivalent tokenizer."
  @spec count(String.t()) :: non_neg_integer()
  def count(text) do
    tokenizer = get_tokenizer()
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, text)
    Tokenizers.Encoding.n_tokens(encoding)
  end

  defp get_tokenizer do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil ->
        {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(tokenizer_path())
        :persistent_term.put(@persistent_term_key, tokenizer)
        tokenizer

      tokenizer ->
        tokenizer
    end
  end

  defp tokenizer_path do
    Application.app_dir(:beamscope, ["priv", "tokenizer", "cl100k_base.tokenizer.json"])
  end
end
