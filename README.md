# Beamlens

Compiler-accurate code intelligence for BEAM codebases (Erlang and Elixir).

Chunking and call-graph extraction are built on `:epp` and `Code.string_to_quoted/2` —
the same frontends the compiler itself uses — instead of a generic tree-sitter
grammar. On Erlang specifically, this means macros are seen exactly as the
compiler sees them: a call hidden behind a `-define`d macro is resolved to its
real target, not left as an opaque token. See `docs/phase0-parity-report.md`
and `docs/phase0-vs-serena-report.md` for the evidence this claim is based on.

## Status

This project has completed Phase 0 (de-risking chunking and call-graph
parity against a real Python/tree-sitter pipeline, on two real production
Erlang codebases) but is **pre-Phase-1**: there is no installer, no MCP
server, and no semantic/embedding-based search yet. What exists today is a
library you can call directly from `iex`/your own code — see below.

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

## What's not built yet

- No semantic/embedding-based search (`search_code`) — no Qdrant/Ollama
  integration exists.
- No MCP server — the functions above are called directly, not exposed as
  MCP tools yet.
- No installer (`mix igniter.install`) — add this repo as a path/git
  dependency for now.
- No incremental indexing — every `chunk_repo`/`extract_repo` call
  re-processes the whole file set. See `docs/incremental-indexing-design.md`
  for a design sketch (not implemented).

## Development

```
mix deps.get
mix test
```

Real-world parity fixtures (full MongooseIM and amoc-arsenal-xmpp checkouts)
live under `priv/fixtures/` but are gitignored — they're research artifacts
for validating parity against the reference Python pipeline, not package
fixtures. The small synthetic `.erl`/`.ex` files alongside them *are* real,
tracked test fixtures.

See `docs/` for the full Phase 0 record: parity investigation, call-graph
validation, and the benchmark against an existing LSP-based code-intelligence
tool.

## License

MIT — see `LICENSE`.
