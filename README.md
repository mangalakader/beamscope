# Beamlens

Compiler-accurate code intelligence for BEAM codebases (Erlang and Elixir).

Chunking and call-graph extraction are built on `:epp` and `Code.string_to_quoted/2` —
the same frontends the compiler itself uses — instead of a generic tree-sitter
grammar. On Erlang specifically, this means macros are seen exactly as the
compiler sees them: a call hidden behind a `-define`d macro is resolved to its
real target, not left as an opaque token, validated against real production
Erlang codebases during Phase 0.

## Status

This project has completed Phase 0 (de-risking chunking and call-graph
parity against a real Python/tree-sitter pipeline, on two real production
Erlang codebases) and has a working MCP server exposing the call graph
plus semantic search. See [Setup](#setup) to add it as a dependency. No
incremental indexing yet — see below.

## Why this project exists

The motivating goal isn't "better code search" in the abstract — it's
**reducing the token cost of using AI coding agents (Claude Code, other
LLM tools) against large Erlang/Elixir codebases**. Structural correctness
(seeing through macros, accurate call graphs) is a means to that end, not
the end itself. See [Token efficiency](#token-efficiency) below for
measured evidence on whether that goal is actually being met.

## Setup

Not published to Hex yet — add as a path or git dependency in the
consuming project's `mix.exs`:

```elixir
def deps do
  [
    {:beamlens, git: "https://github.com/mangalakader/beamlens.git"}
    # or, against a local checkout:
    # {:beamlens, path: "../beamlens_spike"}
  ]
end
```

```
mix deps.get
```

If the consuming project uses [Igniter](https://hexdocs.pm/igniter),
`mix igniter.install beamlens` does the same `mix.exs` edit and prints a
notice listing what's wired up right now.

**Optional — only needed for `search_code` (semantic search)** — add the ML
deps too (see the Semantic search section below for why these are kept
separate/optional rather than required):

```elixir
{:bumblebee, "~> 0.7"},
{:nx, "~> 0.12"},
{:torchx, "~> 0.12"}
```

Building Torchx's NIF needs a C/C++ toolchain and `cmake` on the machine
running `mix deps.get`/`mix compile` the first time — install that first if
you don't already have it (e.g. `brew install cmake` on macOS). Everything
after that is automatic — no Ollama, Qdrant, or Docker to run.

### First run

Start the MCP server:

```
mix beamlens.mcp                # http://localhost:9877/mcp
mix beamlens.mcp --port 8080
```

Point an MCP client at that URL as a remote HTTP server — not a spawned
stdio subprocess, see the MCP server section below. There's no separate
"index this repo" step to run first: every tool call takes an explicit
`repo_path`, and the first call for a given path builds (and caches)
whatever it needs on demand.

- `get_callers`/`get_callees`/`find_call_path` build the call graph on
  first use — seconds for a small repo, longer for a real production-sized
  one (this is the one-time cost of walking and parsing every file).
- `search_code` additionally chunks the repo, embeds every chunk, and
  persists the result to `<repo_path>/.beamlens/search.dets`. The first
  `search_code` call for a repo is the slowest call you'll make — it's also
  the point where the embedding model itself gets downloaded and loaded, if
  this is the first time `Beamlens.Embeddings` has run in this OS process.

Every call after that first one for a given `repo_path` is served from the
in-memory cache. For search, the on-disk `.beamlens/search.dets` file also
survives a server restart, so restarting doesn't re-embed the whole repo.

Without the MCP server, the same operations are available directly:

```elixir
alias Beamlens.Repo

{:ok, %{callers: callers}} = Repo.callers("/path/to/repo", "my_module", "my_function")

{:ok, %{exact_matches: exact, semantic_matches: semantic}} =
  Repo.search("/path/to/repo", "where session tokens get validated", limit: 5)
```

## Incremental indexing

**Not implemented yet.** Every index build — call graph or search — walks
and re-processes every file in the repo from scratch; nothing is tracked
about what changed since the last build. `Beamlens.Repo.reindex/2` (and the
lower-level `Beamlens.Callgraph.Store.reindex/2` /
`Beamlens.Search.Store.reindex/2`) exist today, but they mean "discard the
cache and rebuild everything," not "update only what changed." For a small
repo that's fast enough not to matter; for a large production codebase it's
the same one-time cost as the very first build, paid again on every
reindex.

A design (file-mtime or content-hash based, to only re-process changed
files) has been sketched but not built. Until it exists, the correct
mental model when building against beamlens is: **the index is a
rebuildable cache, not a live-updating one.**

## What works today

**Chunking** — walk a repo and split it into function/attribute-level chunks:

```elixir
alias Beamlens.Chunking.Pipeline

result = Pipeline.chunk_repo("/path/to/repo", max_concurrency: 8)
result.chunks   # [%{symbol:, start_line:, end_line:, text:, kind:, file_path:, warning:}, ...]
result.errors   # [{path, reason}, ...] — timeouts/crashes, doesn't fail the whole run
```

Supports `.erl`/`.hrl` (via `:epp`), `.ex`/`.exs` (via `Code.string_to_quoted/2`),
and falls back to line-window chunking for everything else (docs, config files)
or files that fail to parse. `-include_lib` resolution for third-party rebar3
deps is auto-discovered from `_build/*/lib` unless disabled.

Attach `Beamlens.Chunking.ProgressReporter` for a live progress line (or
periodic log lines when not in a TTY) while a large repo indexes:

```elixir
Beamlens.Chunking.ProgressReporter.attach()
Pipeline.chunk_repo("/path/to/repo")
Beamlens.Chunking.ProgressReporter.detach()
```

**Call graph** — extract function definitions and call edges, then query them:

```elixir
alias Beamlens.Callgraph.{Pipeline, Graph}

%{defs: defs, edges: edges} = Pipeline.extract_repo("/path/to/repo")
graph = Graph.build(defs, edges)

Graph.callers(graph, "my_module:my_function")
Graph.callees(graph, "my_module:my_function")
Graph.shortest_path(graph, "module_a:foo", "module_b:bar")
Graph.to_node_link_json(graph) # NetworkX-node-link-compatible JSON
```

Call targets that can't be statically resolved (dynamic dispatch, e.g.
`Mod:Fun()` where `Mod` is a variable) are marked with callee module `"?"`
rather than silently dropped or misattributed.

**Semantic search** — chunk-level embeddings, searchable by natural-language
query, entirely in-process (no external service):

```elixir
alias Beamlens.Repo

Repo.reindex("/path/to/repo")  # builds the call graph and, if the optional
                                # ML deps below are installed, the search index
Repo.search("/path/to/repo", "where is the session token validated", limit: 5)
# {:ok, %{
#   exact_matches: [%{file_path:, line:, text:}, ...],
#   semantic_matches: [%{file_path:, symbol:, start_line:, end_line:, kind:, score:}, ...],
#   semantic_error: nil
# }}
```

`exact_matches` and `semantic_matches` are two separate lists, not one
blended ranking — an exact match and a similarity score aren't the same
kind of signal, so `search_code` doesn't try to fuse them into a single
score. `exact_matches` is a literal, in-process grep for identifier-like
terms pulled out of the query (see `Beamlens.Search.LexicalSearch`) and
needs no ML deps at all; it exists because semantic search alone reliably
loses to plain grep on exact-name queries ("where is `pop_messages`
defined") — see [Token efficiency](#token-efficiency) below.

Requires the optional `bumblebee`/`nx`/`torchx` deps — add to your own
`mix.exs`:

```elixir
{:bumblebee, "~> 0.7"},
{:nx, "~> 0.12"},
{:torchx, "~> 0.12"}
```

Nothing else to install or run — no Ollama, no Qdrant, no Docker, no
separate server. `Beamlens.Embeddings` loads a small, retrieval-tuned
sentence-embedding model (`BAAI/bge-small-en-v1.5`, ~130MB, downloaded once
on first use and cached by Bumblebee) directly in the BEAM. Uses Torchx as
the `Nx` backend rather than EXLA specifically because EXLA has no native
Windows binaries (Windows needs WSL to use it at all) — Torchx auto-downloads
a precompiled CPU libtorch build and works natively on Windows. **Building
Torchx's NIF requires a C/C++ toolchain and `cmake`** on the machine running
`mix deps.get`/`mix compile` for the first time — this is the one real,
honest prerequisite; everything after that is automatic.

Model choice here went through two real, measured revisions, not a single
guess — see `Beamlens.Embeddings`'s moduledoc for the full account:
`sentence-transformers/all-MiniLM-L6-v2` (the original choice) mis-ranked
an exact-name match in real testing; `nomic-ai/nomic-embed-text-v1` (same
model family the original Python/Ollama reference pipeline used) fixed
that class of problem in principle but measured at **117 seconds for a
single cold call** on Torchx's eager (no-JIT) CPU execution and kept
straining the machine on warm calls too — disqualifying for an interactive
tool. `bge-small-en-v1.5` is back in MiniLM's size/speed class (fast, no
custom-architecture risk) but — unlike MiniLM — is trained specifically
for asymmetric query/passage retrieval.

The index is persisted to `<repo_path>/.beamlens/search.dets` (a build
artifact, like `_build/` — gitignore it in the target repo) so a server
restart doesn't require re-embedding the whole repo.

If the ML deps aren't installed, `semantic_matches` comes back empty with
`semantic_error: :embeddings_not_available` rather than the whole call
failing — `exact_matches` still works, and `get_callers`/`get_callees`/
`find_call_path` work with zero ML dependencies at all.

**MCP server** — exposes `get_callers`, `get_callees`, `find_call_path`,
`search_code` as MCP tools, all routed through `Beamlens.Repo` (which
delegates to `Beamlens.Callgraph.Store`/`Beamlens.Search.Store`, each
building and caching per repo path on first use):

```
mix beamlens.mcp              # listens on http://localhost:9877/mcp
mix beamlens.mcp --port 8080
```

Runs over **HTTP, not stdio** — most local MCP clients (Claude Desktop,
Claude Code) default to spawning a subprocess and talking over stdio, but
this matches how [Tidewave](https://hexdocs.pm/tidewave/mcp.html), the
most prominent production Elixir MCP server, does it too: mounted HTTP,
not a spawned stdio subprocess. Connect an MCP client to
`http://localhost:9877/mcp` as a remote server.

The MCP layer (`Beamlens.MCP.Protocol`/`Beamlens.MCP.Router`) is built
directly on `Plug` + `Bandit` + `Jason` — no MCP protocol library. A
handful of stateless tools don't need a full client/server SDK (session
tracking, SSE, batching, capability negotiation beyond `tools`); a
~90-line JSON-RPC dispatcher covers exactly what's needed and avoids
taking on a large, mostly-unused dependency tree for it.

## What's not built yet

- No incremental indexing — see the [Incremental indexing](#incremental-indexing)
  section above.
- Not published to Hex — see [Setup](#setup) above for the path/git
  dependency + `mix igniter.install beamlens` alternative.

## Token efficiency

The point of building this on `:epp`/`Code.string_to_quoted` instead of
tree-sitter was never "better architecture" for its own sake — it's
**reducing how many tokens an AI coding agent burns navigating a large
Erlang/Elixir codebase**. The full writeup —
[docs/search-benchmark-2026-07.md](docs/search-benchmark-2026-07.md) —
is a real, 18-task benchmark across three real codebases (MongooseIM,
amoc-arsenal-xmpp, and the Elixir language's own source), replacing the
earlier 5-query/char-estimate spot-check: real `tiktoken` token counts (not
a char/4 estimate), real grep/read baselines, and 3 tasks cross-checked
against an actual live subagent restricted to grep/read only.

Headline numbers (16 scored tasks, full detail in the linked report):

| | Baseline (grep/read) | Beamlens (MCP tool) | Reduction |
|---|---:|---:|---:|
| **Total tokens** | 1,355,159 | 5,807 | **99.6%** |
| `get_callers`/`get_callees`/`find_call_path` (11 tasks) | — | — | 100% passed quality grading, 98–99.95% reduction |
| `search_code` (5 tasks) | — | — | mixed quality (see below), 95.7–99.6% reduction |

**Quality is genuinely bimodal for `search_code`, confirmed independently on
three separate codebases**: conceptual queries ("code that does X", no name
given) pass cleanly; exact-name queries ("where is `foo` defined") lose to
grep every time, because semantic search is probabilistic ranking and grep
is a guaranteed exact match — the wrong tool for a task that already has an
exact string to match against. `search_code` now addresses this directly:
it also returns `exact_matches`, a literal grep for identifier-like terms
in the query, alongside (not blended into) `semantic_matches` — see
[Semantic search](#incremental-indexing) above. Use `exact_matches` (or
`get_callers`/`get_callees` once you have a name) for exact lookups; lean
on `semantic_matches` when you don't know what to grep for.

**Efficiency**: building the call graph is fast even at full-repo scale
(3.7s for the entire Elixir language monorepo) and every later query is
sub-second. `search_code` originally measured 16–46 *seconds* per query
(even warm) and 6.5–12 *minutes* to cold-index even a small directory — not
the vector-search step (always sub-second) but two compounding bugs in
`Beamlens.Embeddings`: every short query was padded up to a full `32×512`
tensor (~1000x needless compute), and each call rebuilt the model's whole
computation graph from scratch instead of reusing an already-running
serving. Fixed by compiling a dedicated small serving for queries and
switching to `Nx.Serving`'s stateful/process workflow — now **1.4s for a
fully cold call, ~70ms warm**, without adding an external vector database
(that would only speed up the search step, which was never the slow part).
Full diagnosis in
[docs/search-benchmark-2026-07.md](docs/search-benchmark-2026-07.md).

**Discover + edit, the full task, not just discovery**: `get_callers`/
`get_callees` now return each caller/callee enriched with its definition's
`file_path`/`start_line`/`end_line` (the call graph already had this
internally, it just wasn't surfaced) — so editing a found call site only
needs the enclosing function, not the whole file. Measured for real on one
task (11 real callers, 8 files): discovery alone is a 99.0% reduction (665
vs. 10,003 tokens for the now-enriched response), and the full discover+edit
task — enriched response plus reading just each real call site's enclosing
snippet, using the locations the tool now returns directly — comes to
1,281 tokens vs. the same 10,003-token baseline, an **87.2% reduction**.
Full numbers in
[docs/search-benchmark-2026-07.md](docs/search-benchmark-2026-07.md).

## Development

```
mix deps.get
mix test
```

Tests tagged `:external` (`Beamlens.Embeddings`/`Beamlens.Search.Store`
real embedding tests) are excluded by default since they hit a real
model download + CPU inference — run `mix test --include external` to
include them.

Real-world parity fixtures (full MongooseIM and amoc-arsenal-xmpp checkouts)
live under `priv/fixtures/` but are gitignored — they're research artifacts
for validating parity against the reference Python pipeline, not package
fixtures. The small synthetic `.erl`/`.ex` files alongside them *are* real,
tracked test fixtures.

## License

MIT — see `LICENSE`.
