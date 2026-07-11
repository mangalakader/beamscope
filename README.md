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
Erlang codebases) and has a working MCP server exposing the call graph.
No installer and no semantic/embedding-based search yet — see below.

## Why this project exists

The motivating goal isn't "better code search" in the abstract — it's
**reducing the token cost of using AI coding agents (Claude Code, other
LLM tools) against large Erlang/Elixir codebases**. Structural correctness
(seeing through macros, accurate call graphs) is a means to that end, not
the end itself. See [Token efficiency](#token-efficiency) below for
measured evidence on whether that goal is actually being met.

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

**MCP server** — exposes `get_callers`, `get_callees`, `find_call_path` as
MCP tools, backed by `Beamlens.Callgraph.Store` (builds and caches a graph
per repo path on first use):

```
mix beamlens.mcp              # listens on http://localhost:9877/mcp
mix beamlens.mcp --port 8080
```

Runs over **streamable HTTP, not stdio**. Most local MCP clients (Claude
Desktop, Claude Code) default to spawning a subprocess and talking over
stdio, but `hermes_mcp` 0.14.1's stdio transport has a confirmed bug where
every single (non-batched) JSON-RPC message crashes the connection
(`Message.decode/1` always returns a list; `STDIO.process_message/2`
doesn't unwrap it before dispatching). Reproduced directly against the
library; no newer release exists yet. HTTP transport doesn't share the
bug — this also matches how [Tidewave](https://hexdocs.pm/tidewave/mcp.html),
the most prominent production Elixir MCP server, does it: mounted HTTP,
not a spawned stdio subprocess. Connect an MCP client to
`http://localhost:9877/mcp` as a remote server.

## What's not built yet

- No semantic/embedding-based search (`search_code`) — no Qdrant/Ollama
  integration exists yet. This is also the fix for the one gap found in
  the token-efficiency check below (no symbol/definition lookup tool) —
  once `search_code` returns file/line/module for a match, that gap
  closes as a side effect rather than needing a separate tool.
- No installer (`mix igniter.install`) — add this repo as a path/git
  dependency for now.
- No incremental indexing — every `chunk_repo`/`extract_repo` call
  re-processes the whole file set (design sketched, not implemented).

## Token efficiency

The point of building this on `:epp`/`Code.string_to_quoted` instead of
tree-sitter was never "better architecture" for its own sake — it's
**reducing how many tokens an AI coding agent burns navigating a large
Erlang/Elixir codebase**. This was checked directly: 4 independent,
real single-query tests against the actual MongooseIM codebase, each
comparing (a) a baseline agent using only grep/read against the real
source, vs. (b) the same question asked through beamlens's MCP tools.
Sizes are the actual bytes returned by each approach, converted to a
token estimate at ~4 characters/token.

| Task | Baseline (grep/read) | Beamlens (MCP tool) | Reduction |
|---|---:|---:|---:|
| `get_callers` — 116 callers, obscured by the `?FUNCTION_NAME` macro | ~33,700 tokens | ~1,125 tokens | **97%** |
| `find_call_path` — genuine 3-hop call chain | ~2,128 tokens | ~52 tokens | **97.5%** |
| `get_callees` — moderate case, 2 callees, targeted read | ~137 tokens | ~26 tokens | **81%** |
| Simple "where is X defined?" | ~71 tokens | *(no tool exists yet)* | **0%** |

**What this shows:** for every task shape the 3 existing tools actually
cover — who calls this, what does this call, how does A reach B — the
reduction is large and consistent, not just true in a cherry-picked
worst-case for grep. It held even in the deliberately "moderate, already
using a targeted read" test, which is the fairest proxy for a typical
query. The `mongoose_backend:call_tracked/4` case is a good illustration
of *why*: every call site uses the `?FUNCTION_NAME` macro (Erlang's
"current function's name" builtin) as the argument, so grep's matched
lines alone don't reveal which function is actually calling — a baseline
agent has to open every file and read around each hit to find out. Grep
also only found 108 matches (scoped to `src/`); the real call graph found
**116** — the naive approach isn't just more expensive here, it's
incomplete.

**What this doesn't show:** these measure the *discovery* step in
isolation, not a full end-to-end task. If the actual job is "add a
parameter to `call_tracked` and update all 116 callers," both approaches
still have to read and edit those same 116 call sites — that shared cost
dominates the total, and discovery's share of it shrinks accordingly. The
0%-reduction row is real too: there's no symbol/definition-lookup tool
yet, and grep already answers that case in one call, so beamlens
currently adds nothing for that task shape (tracked as a known gap above,
expected to close once `search_code` ships file/line/module per match).

This will be re-measured and reported here once `search_code` exists.

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

## License

MIT — see `LICENSE`.
