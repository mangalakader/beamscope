defmodule Beamscope.Embeddings do
  @moduledoc """
  In-process text embeddings via Bumblebee — no external service, no
  Ollama/Qdrant, nothing to install or run outside `mix deps.get`.

  `bumblebee`/`nx`/`torchx` are optional dependencies (see `mix.exs`), so
  this module compiles fine without them installed — plain remote calls
  don't require the callee module to exist at compile time in Elixir, only
  at the moment they actually run. `embed_query/1`/`embed_documents/1`
  check `available?/0` first and return `{:error, :embeddings_not_available}`
  rather than reaching those calls when the deps aren't installed.

  Uses Torchx (not EXLA) as the Nx backend: EXLA has no native Windows
  binaries (Windows needs WSL to use it at all), while Torchx auto-downloads
  a precompiled CPU libtorch build that works natively on Windows. Torchx is
  a backend, not a `Nx.Defn` JIT compiler — no `defn_options: [compiler: ...]`
  below, so every call runs eagerly. This is the reason model choice here is
  conservative: `nomic-ai/nomic-embed-text-v1` (768-dim, RoPE, 1024-token
  sequence) was tried first for its stronger retrieval quality, but measured
  at **117 seconds for a single cold call** on eager Torchx and kept
  straining the CPU on warm calls too — disqualifying for an interactive
  MCP tool. `BAAI/bge-small-en-v1.5` is the same size/architecture class as
  the original `all-MiniLM-L6-v2` choice (small vanilla BERT, no RoPE, fast
  eager execution) but — unlike MiniLM — is trained specifically for
  asymmetric query/passage retrieval, which is the property that was
  actually missing (MiniLM mis-ranked an exact-name match behind a
  merely-similar-named function in real testing).

  BGE's retrieval tuning only requires an instruction prefix on the *query*
  side (`"Represent this sentence for searching relevant passages: "`) —
  passages/documents are embedded with no prefix. `embed_query/1` and
  `embed_documents/1` stay separate entry points (rather than one generic
  `embed/1`) so this asymmetry can't be gotten wrong by accident at a call
  site — and, just as importantly now, because each needs its own compiled
  shape (see below).

  Loaded lazily on first use, not at application boot — mirrors
  `Beamscope.Callgraph.Store`'s lazy-build-on-first-use pattern, so starting
  the MCP server for call-graph-only usage doesn't pay a model-download/load
  cost it doesn't need.

  ## Two servings, not one, and the "stateful process" API, not "inline"

  A single-serving, `Nx.Serving.run/2`-based design measured at **16-46
  seconds per query** — traced to two independent, compounding bugs, not
  inherent model slowness (a same-class CPU model elsewhere embeds a short
  sentence in ~20ms):

  1. **Shape overcompute.** A bare-integer `sequence_length` pads every
     input to that full length regardless of real length, and `batch_size`
     pads any smaller batch up to the full compiled size — so a single
     ~15-token query compiled with `sequence_length: 512, batch_size: 32`
     doesn't run a `1×15` tensor, it runs a `32×512` tensor, ~1000x more
     self-attention compute than needed. Fixed here by compiling a
     dedicated, small-shaped serving for queries (`@query_batch_size`,
     `@query_sequence_length`) separate from the document/chunk serving,
     which keeps its larger shape since batch indexing genuinely benefits
     from it.
  2. **Per-call graph retracing.** `Nx.Serving.run/2` is Nx's documented
     "inline/serverless" API — every call retraces the entire model's
     computation graph from scratch, independent of shape. Caching the
     `%Nx.Serving{}` struct (what this module used to do) avoids
     re-downloading weights but not this retracing. Fixed by using Nx's
     "stateful/process" workflow instead: each serving is started once via
     `Nx.Serving.start_link/1` (as a `DynamicSupervisor` child, so it's
     still only paid on first real use — see
     `Beamscope.Embeddings.ServingSupervisor` in the application's
     supervision tree),
     and every embed call goes through `Nx.Serving.batched_run/2` against
     the already-running named process instead of building/tracing inline.
  """

  use GenServer

  require Logger

  @model {:hf, "BAAI/bge-small-en-v1.5"}
  @query_instruction "Represent this sentence for searching relevant passages: "
  @required_mods [Bumblebee, Nx, Torchx]

  @query_serving_name __MODULE__.QueryServing
  @document_serving_name __MODULE__.DocumentServing
  # Queries are short (a handful of words) — a small, dedicated shape avoids
  # padding every query up to the document serving's much larger shape.
  @query_batch_size 1
  @query_sequence_length 64
  # Unchanged from before: batch indexing genuinely benefits from a larger
  # shape, since code chunks run well beyond query-length.
  @document_batch_size 32
  @document_sequence_length 512
  @batch_timeout 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, nil, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Whether the optional ML dependencies (bumblebee/nx/torchx) are installed."
  @spec available?() :: boolean()
  def available?, do: Enum.all?(@required_mods, &Code.ensure_loaded?/1)

  @doc "Embeds a single search query, returning its vector as a plain float list."
  @spec embed_query(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed_query(text) do
    with {:ok, [vector]} <- run_batch(:query, [@query_instruction <> text]), do: {:ok, vector}
  end

  @doc """
  Embeds a batch of documents/chunks (e.g. code chunks being indexed) in one
  model call, returning one vector per input, in order.
  """
  @spec embed_documents([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed_documents(texts) when is_list(texts) do
    run_batch(:document, texts)
  end

  defp run_batch(kind, texts) do
    if available?() do
      GenServer.call(__MODULE__, {:embed_batch, kind, texts}, :infinity)
    else
      {:error, :embeddings_not_available}
    end
  end

  @impl true
  def init(nil), do: {:ok, :not_loaded}

  @impl true
  def handle_call({:embed_batch, kind, texts}, _from, state) do
    :loaded = ensure_loaded(state)

    case run_serving(serving_name(kind), texts) do
      {:ok, vectors} -> {:reply, {:ok, vectors}, :loaded}
      {:error, reason} -> {:reply, {:error, reason}, :loaded}
    end
  end

  defp serving_name(:query), do: @query_serving_name
  defp serving_name(:document), do: @document_serving_name

  # A single bad input (e.g. non-UTF-8 text — see Beamscope.Search.Store's
  # filter, which is the primary defense) can make the tokenizer raise deep
  # in a Rustler NIF in a way Bumblebee itself doesn't handle. Catching it
  # here, rather than letting it crash this GenServer, avoids losing the
  # already-started (and already-expensive-to-retrace) serving processes.
  defp run_serving(serving_name, texts) do
    results = Nx.Serving.batched_run(serving_name, texts)
    vectors = Enum.map(results, fn %{embedding: embedding} -> Nx.to_flat_list(embedding) end)
    {:ok, vectors}
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:error, "embedding failed: #{Exception.message(e)}"}
  catch
    :exit, reason ->
      Logger.error("embed_batch exited: #{inspect(reason)}")
      {:error, "embedding failed: #{inspect(reason)}"}
  end

  defp ensure_loaded(:loaded), do: :loaded

  defp ensure_loaded(:not_loaded) do
    Nx.default_backend({Torchx.Backend, device: :cpu})

    {:ok, model_info} = Bumblebee.load_model(@model)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(@model)

    start_serving(
      @query_serving_name,
      model_info,
      tokenizer,
      @query_batch_size,
      @query_sequence_length
    )

    start_serving(
      @document_serving_name,
      model_info,
      tokenizer,
      @document_batch_size,
      @document_sequence_length
    )

    :loaded
  end

  defp start_serving(name, model_info, tokenizer, batch_size, sequence_length) do
    serving =
      Bumblebee.Text.text_embedding(model_info, tokenizer,
        compile: [batch_size: batch_size, sequence_length: sequence_length],
        output_pool: :mean_pooling,
        output_attribute: :hidden_state,
        embedding_processor: :l2_norm
      )

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Beamscope.Embeddings.ServingSupervisor,
        {Nx.Serving,
         serving: serving, name: name, batch_size: batch_size, batch_timeout: @batch_timeout}
      )

    :ok
  end
end
