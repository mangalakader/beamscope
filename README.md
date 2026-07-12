# Beamlens

Compiler-accurate code intelligence for BEAM codebases (Erlang and Elixir).

Chunking and call-graph extraction are built on `:epp` and
`Code.string_to_quoted/2` — the same frontends the compiler itself uses —
instead of a generic tree-sitter grammar. On Erlang specifically, this
means macros are seen exactly as the compiler sees them: a call hidden
behind a `-define`d macro resolves to its real target, not an opaque
token.

Built to reduce the token cost of AI coding agents (Claude Code, and
similar tools) working against large Erlang/Elixir codebases — in
benchmarks across three real codebases, using beamlens instead of raw
grep/read cuts token usage by 90–100% on call-graph queries. See
[ENGINEERING.md](ENGINEERING.md) for the architecture decisions,
benchmark methodology, and full results.

## Status

Chunking and call-graph parity are validated against real production
Erlang codebases. The MCP server (call graph + semantic search) works
end-to-end and is verified as a real `mix` dependency in an external
Elixir app. **No incremental indexing yet** — every index build
reprocesses the whole repo from scratch (see
[Limitations](#limitations)). Not yet published to Hex — see
[Setup](#setup).

## Setup

Not published to Hex yet — add as a git or path dependency in the
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

If the consuming project uses [Igniter](https://hexdocs.pm/igniter), one
command does the same `mix.exs` edit and prints a notice listing what's
wired up right now. Since this isn't on Hex yet, point it at the git repo
directly with the `@git:`/`@github:` syntax (a bare `mix igniter.install
beamlens` only works once this is published to Hex):

```
mix igniter.install beamlens@git:https://github.com/mangalakader/beamlens.git
# or: mix igniter.install beamlens@github:mangalakader/beamlens
```

**Ignore the build artifacts.** Once you index a repo (see below), beamlens
writes `<repo_path>/.beamlens/` there — a rebuildable cache, like `_build/`,
not something to commit or ship. Add to the *consuming* project's
`.gitignore` (and `.dockerignore`, if you build container images):

```
.beamlens/
```

**Optional — only needed for `search_code` (semantic search)** — add the ML
deps too:

```elixir
{:bumblebee, "~> 0.7"},
{:nx, "~> 0.12"},
{:torchx, "~> 0.12"}
```

Building Torchx's NIF needs a C/C++ toolchain and `cmake` on the machine
running `mix deps.get`/`mix compile` the first time — install that first if
you don't already have it (e.g. `brew install cmake` on macOS). Everything
after that is automatic — no Ollama, Qdrant, or Docker to run.

## First run

Start the MCP server:

```
mix beamlens.mcp                # http://localhost:9877/mcp
mix beamlens.mcp --port 8080
```

Connect an MCP client to that URL as a remote HTTP server (not a spawned
stdio subprocess). There's no separate "index this repo" step: every tool
call takes an explicit `repo_path`, and the first call for a given path
builds (and caches, and persists to `<repo_path>/.beamlens/`) whatever it
needs on demand.

- `get_callers`/`get_callees`/`find_call_path` build the call graph on
  first use — seconds for a small repo, longer for a real production-sized
  one (this is the one-time cost of walking and parsing every file).
- `search_code` additionally chunks the repo and embeds every chunk. The
  first `search_code` call for a repo is the slowest call you'll make —
  it's also the point where the embedding model gets downloaded, if this
  is the first time it's run on this machine.

Every call after the first for a given `repo_path` is served from an
in-memory cache, and the on-disk `.beamlens/` files survive a server
restart too — nothing needs to rebuild just because the server restarted.

Without the MCP server, the same operations are available directly:

```elixir
alias Beamlens.Repo

{:ok, %{callers: callers}} = Repo.callers("/path/to/repo", "my_module", "my_function")

{:ok, %{exact_matches: exact, semantic_matches: semantic}} =
  Repo.search("/path/to/repo", "where session tokens get validated", limit: 5)
```

## Usage

**Call graph** — who calls what, and how to get from A to B:

```elixir
alias Beamlens.Repo

{:ok, %{callers: callers}} = Repo.callers("/path/to/repo", "my_module", "my_function")
{:ok, %{callees: callees}} = Repo.callees("/path/to/repo", "my_module", "my_function")
{:ok, %{path: path}} = Repo.call_path("/path/to/repo", "mod_a", "foo", "mod_b", "bar")
```

Each caller/callee comes back enriched with its definition's
`file_path`/`start_line`/`end_line`, so acting on a result doesn't require
re-reading the whole file it lives in.

**Semantic search** — chunk-level embeddings, searchable by natural-language
query, entirely in-process (no external service, no Ollama/Qdrant/Docker):

```elixir
Repo.search("/path/to/repo", "where is the session token validated", limit: 5)
# {:ok, %{
#   exact_matches: [%{file_path:, line:, text:}, ...],
#   semantic_matches: [%{file_path:, symbol:, start_line:, end_line:, kind:, score:}, ...],
#   semantic_error: nil
# }}
```

`exact_matches` and `semantic_matches` are two separate lists, not one
blended ranking. `exact_matches` is a literal, in-process grep for
identifier-like terms in the query and needs no ML deps; use it (or
`get_callers`/`get_callees` once you have a name) for exact-name lookups.
Lean on `semantic_matches` when you don't know what to grep for. If the
optional ML deps aren't installed, `semantic_matches` comes back empty
with `semantic_error: :embeddings_not_available` rather than the whole
call failing.

**Chunking** — the lower-level building block, if you need
function/attribute-level chunks directly:

```elixir
alias Beamlens.Chunking.Pipeline

result = Pipeline.chunk_repo("/path/to/repo", max_concurrency: 8)
result.chunks   # [%{symbol:, start_line:, end_line:, text:, kind:, file_path:, warning:}, ...]
result.errors   # [{path, reason}, ...] — timeouts/crashes, doesn't fail the whole run
```

Supports `.erl`/`.hrl` (via `:epp`), `.ex`/`.exs` (via
`Code.string_to_quoted/2`), and falls back to line-window chunking for
everything else (docs, config files) or files that fail to parse.

## Benchmarking your own repo

```
mix beamlens.benchmark --repo /path/to/repo [--repo /path/to/repo2] [--output docs/benchmarks/]
```

Auto-discovers representative tasks in the repo, measures real token
counts and latency for beamlens vs. a grep/read baseline, and writes a
timestamped Markdown report. See [ENGINEERING.md](ENGINEERING.md) for the
methodology and results this same tool produced against MongooseIM,
amoc-arsenal-xmpp, and the Elixir language's own source.

The token-count/reduction table works with no extra setup. The latency
comparison table needs `Benchee`; add `{:benchee, "~> 1.3", only: :dev}`
to your own `mix.exs` deps to get it — without it, the benchmark still
runs and reports token counts, just without that section.

## Limitations

- **No incremental indexing.** Every index build — call graph or search —
  reprocesses every file in the repo from scratch; nothing is tracked
  about what changed since the last build. `Repo.reindex/2` means
  "discard the cache and rebuild everything," not "update only what
  changed." For a small repo that's fast enough not to matter; for a
  large production codebase it's the same one-time cost as the very first
  build, paid again on every reindex. The mental model: **the index is a
  rebuildable cache, not a live-updating one.**
- **Not published to Hex yet** — see [Setup](#setup) above.

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
for validating parity against a reference pipeline, not package fixtures.
The small synthetic `.erl`/`.ex` files alongside them *are* real, tracked
test fixtures.

## License

MIT — see `LICENSE`.
