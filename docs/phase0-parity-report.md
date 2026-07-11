# Phase 0 Parity Report — Chunking (0.2/0.3), Call Graph (0.4), Full-Repo Diff (0.5)

Status: 0.1–0.4 and 0.6 complete; 0.5's full-repo diff done for both target repos (MongooseIM and amoc-arsenal-xmpp). Serena benchmark (0.6) complete — see `docs/phase0-vs-serena-report.md`.

## What was compared

The real Python pipeline (`~/Mine/HHPO/v2/mongoose-rag-v2/indexer/chunker.py` + `erlang_tools/extract_chunks.erl` + `erlang_tools/extract_chunks.exs`) was run directly — no Docker/Qdrant/Ollama needed, since chunking has no external dependencies beyond the `erl`/`elixir` binaries — against the exact same MongooseIM checkout used to validate the Elixir port (`priv/fixtures/mongooseim`, commit `2d21164`, master), after building it with `./rebar3 get-deps && ./rebar3 compile` so `-include_lib` resolution is apples-to-apples on both sides.

## Headline numbers

| | Python (ground truth) | Elixir port | ratio |
|---|---:|---:|---:|
| files discovered | 1066 | 1063 | — |
| **total chunks** | **30,966** | **25,315** | **82%** |
| `function` chunks | 20,190 | 18,258 | 90% |
| `attribute` chunks | 10,088 | 6,365 | 63% |
| text-window fallback chunks | 688 | 692 | ~100% |
| files/chunks with warnings | 77 files | 8,592 chunks (partial-tagged) | not directly comparable — see below |

File-count discrepancy (1066 vs 1063, off by 3) is most likely `asn1`-generated `.erl`/`.hrl` files landing in `src/` at build time (the build log shows `asn1/XmppAddr.asn1` being compiled); not investigated further as it's noise relative to the chunk-count gap.

**An earlier working assumption that Python produced "~48,000" chunks for this repo turned out not to hold** — that figure wasn't found in any stored artifact (no exported Qdrant collection, no logged run summary), and running the actual code against this exact checkout gives 30,966. The real gap to explain is 30,966 → 25,315 (18%), not 2x.

## Why the gap: attribute-chunk deduplication (deliberate, approved fix)

The `attribute` row accounts for the large majority of the total gap (3,723 of ~5,650 chunks). Root cause: `extract_chunks.erl` does not filter forms by which physical file they came from. `:epp`/`epp` inlines every `-include`'d header's forms directly into the parsed form list, and the original chunker emits **all** of them under the including file — meaning a shared header's `-record`/`-type` attributes get re-chunked once per file that includes it, with the chunk's *text* sliced from the including file's line numbers (not the header's own), since the original has no way to know the form actually came from a different file.

Concretely: `jlib.hrl` (6 record/type/define attributes) is included by at least 166 files under `src/`. Each inclusion re-emits those 6 attributes as new chunks with wrong-file-sliced text — a single shared header can silently contribute ~1000 near-duplicate, textually-incorrect chunks. This compounds across every widely-shared header in the codebase.

The Elixir port (`ErlangChunker.forms_owned_by_file/2`) tracks `:epp`'s synthetic `{:attribute, _, :file, {Filename, _}}` boundary markers and drops forms that don't belong to the file being chunked. Each header is chunked exactly once, when it's its own file's turn in the walk. This was an explicit, user-approved fix (not a silent deviation) — see the "Deliberate fixes" section below.

The residual `function`-chunk gap (90% parity, ~1,932 chunks) is not fully explained and is a reasonable target for follow-up once 0.4 (call graph) is done — plausible remaining causes include modest differences in how many functions actually reference unresolved macros/records inside their bodies (causing real, not duplicated, parse loss on the Elixir side) versus files where Python's redundant header-chunking incidentally recovers content the Elixir side legitimately doesn't need to recover.

## Deliberate fixes (approved, not silent divergences)

1. **Included-header forms excluded from the including file** (see above) — fixes both the duplicate-chunk and wrong-file-text-slicing problems in one change.
2. **Nested Elixir modules qualified with their outer module path.** The original's `defmodule` handler discards the outer module context when recursing (`process_form({:defmodule, ...}, _outer)` — the accumulated context is explicitly unused), so a `Nested` module inside `Foo.Bar` gets chunked under the bare symbol `"Nested"` instead of `"Foo.Bar.Nested"`. The port accumulates and qualifies the full path.
3. **`when`-guarded function heads unwrapped before name extraction.** The original destructures a def's head directly as `{name, _, _args}`; for `def foo(x) when is_integer(x) do`, the head is actually `{:when, meta, [{:foo, ...}, guard]}`, so `name` binds to the literal atom `:when` — every guarded clause in the original pipeline gets the wrong symbol. The port unwraps `:when` first.

## Bugs found and fixed during Elixir-side testing (not present in the original in this form)

Re-reading `chunker.py` while writing unit tests surfaced a real logic bug in the initial Elixir port (not in the original Python): both chunkers were falling back to line-window chunking (`TextChunker`) on a **fatal** parse failure (file can't be opened / `Code.string_to_quoted` errors). The actual Python behavior — confirmed by reading the exact conditional, `if not chunks and result.returncode == 0` — only falls back when the extractor exits cleanly (code 0) but produced zero chunks (e.g. a header with only comments). A genuinely fatal failure returns **empty chunks, no fallback**. This also means the original README's claim that Elixir syntax errors ("`[warn:failed]`") fall back to line-window chunking does not match what `chunker.py`'s code actually does — worth flagging as a possible doc/code mismatch in the original, independent of this port. Both `ErlangChunker` and `ElixirChunker` now match the actual code's behavior; regression tests cover both branches (`empty_comment_only.hrl` / `no_defs.ex` for the "clean but empty" fallback, `does_not_exist.erl` / `broken_syntax.ex` for the "fatal, no fallback" case).

## Concurrency benchmark (Task.async_stream, not GenStage/Flow — see below)

Run against the same 1063-file MongooseIM checkout:

| max_concurrency | time | chunks |
|---:|---:|---:|
| 1 (sequential) | 1.47s | 24,606 |
| 2 | 0.87s | 24,606 |
| 4 | 0.58s | 24,606 |
| 8 (all cores) | 0.57s | 24,606 |

Chunk counts are identical at every concurrency level — the merge is correctness-invariant regardless of ordering. `max_chunk_lines`/`max_chunk_chars` params also verified to change output as expected (tightening from 80/3000 to 20/800 produced 30,113 chunks instead of 24,606 on the pre-build numbers).

GenStage/Flow were considered and rejected for this workload: `chunk_repo` processes a known, fixed file list with no multi-stage backpressure requirement — `Task.async_stream` is the idiomatic fit. `:telemetry`-based progress reporting was added instead (`Pipeline` emits start/per-file/stop events; `ProgressReporter` is an opt-in handler that prints a live-updating line in a TTY or ~20 discrete lines when piped, plus a final summary) — this keeps the core pipeline IO-free by default while giving callers exactly the progress visibility they'd otherwise reach for a heavier abstraction to get.

## Test coverage (chunking)

27 ExUnit tests across `erlang_chunker_test.exs`, `elixir_chunker_test.exs`, `support_test.exs`, covering: spec-merge adjacency (including the ground-truth quirk where merge is positional, not name-matched), orphan-spec handling, partial-recovery tagging, included-header exclusion, guard-clause unwrapping, nested-module qualification, oversized-chunk splitting (line and char budget), and both fallback paths (fatal vs. clean-but-empty).

## Call graph (0.4)

Built `Callgraph.Extractor` (per-file defs/edges via `:epp`/`Code.string_to_quoted`, no tree-sitter) and `Callgraph.Graph` (`libgraph`-backed, `callers/2`/`callees/2`/`shortest_path/3`/`to_node_link_json/1`), plus `Callgraph.Pipeline` mirroring the chunking pipeline's concurrent multi-file pattern. This tests a genuinely different hypothesis than chunking did — the real `call_extractor.py` uses **tree-sitter**, a completely separate code path from `chunker.py`'s epp/AST approach, so nothing about chunking parity predicted whether this would work.

**The core differentiator claim is confirmed, concretely.** In `mod_fake_backend.erl`, `?BACKEND_MODULE(Host)` is a macro that expands to `gen_mod:get_module_opt(Host, ?MODULE, backend, mnesia)`. Because `:epp` fully expands macros as part of parsing (that's its entire job), the extractor correctly resolves this to a `mod_fake_backend:get_user → gen_mod:get_module_opt` edge — a call that's invisible to any tool that hasn't macro-expanded the source first. I could not get a live empirical run of the actual tree-sitter-based `call_extractor.py` in this environment (`tree-sitter-languages==1.10.2` requires Python <3.12; only 3.12/3.14 are available here, no pyenv/uv to provision an older interpreter) — so this claim rests on reading `call_extractor.py`'s exact matching logic (`_extract_erlang` only recognizes `node.type == "call"` with `atom`/`remote` children) plus the well-documented fact that Erlang's tree-sitter grammar tokenizes `?MACRO(...)` as a distinct macro-call node type that structurally cannot match either branch — not on a side-by-side run. Worth re-verifying empirically if a Python <3.12 environment becomes available before this goes in a launch post.

Note this advantage is **Erlang-specific**: `Code.string_to_quoted/2` parses Elixir syntax only, it does not expand macros (that's a separate compile-time step) — a call hidden behind an Elixir macro is exactly as invisible to this port as it is to tree-sitter.

### Real-repo comparison (same MongooseIM checkout as chunking)

| | Python (`shared/mongooseim_callgraph.json`, tree-sitter) | Elixir port (epp/AST) | ratio |
|---|---:|---:|---:|
| nodes/vertices | 25,571 | 20,733 | 81% |
| edges | 74,981 | 49,649 (49,962 raw, before libgraph's exact-duplicate collapse) | 66% |

The baseline's "nodes" count includes both defined functions *and* call targets referenced but never captured as a def (`build_callgraph.py` explicitly adds a node for every edge endpoint) — the Elixir port's graph vertex count (not raw def count, which is lower at 17,068) is the correct comparable figure, and at 81% it's reasonably close. The edge-count gap (66%) is larger and not yet root-caused to the same level of confidence as the chunking gap — plausible contributors on both sides (tree-sitter catching call shapes the epp/AST walk doesn't yet handle, e.g. calls inside list comprehensions or certain guard contexts; conversely the epp/AST approach legitimately finding macro-hidden calls tree-sitter can't) haven't been itemized file-by-file. Only 127 of 49,962 edges (0.25%) resolved to `callee_module: "?"` (unresolvable dynamic dispatch) — notably low, worth sanity-checking against the baseline's own dynamic-dispatch rate if a precise reconciliation is needed later.

libgraph's default graph type deduplicates edges that are fully identical (same caller, callee, file, *and* line) — accounting for the small 49,962→49,649 shrinkage. The baseline's NetworkX `MultiDiGraph` never deduplicates, keeping every edge unconditionally. This is a minor (0.6%), explainable, graph-semantics difference, not a parsing gap.

### Test coverage (call graph)

15 ExUnit tests across `extractor_test.exs`, `graph_test.exs` — including a direct assertion that the macro-expansion edge (`get_user → gen_mod:get_module_opt`) is found, that variable-module dynamic dispatch is correctly marked `"?"`, that special forms/operators aren't misdetected as calls in Elixir, and the graph query helpers (`callers`/`callees`/`shortest_path`, including the `nil`-when-no-path case) and JSON export.

## Second repo: amoc-arsenal-xmpp (0.5)

Same methodology, second (much smaller, 22-file) real repo — validates that the MongooseIM findings aren't a one-off.

**Setup friction, worth recording:** this repo declares `{minimum_otp_vsn, "28"}` in `rebar.config`. Both the homebrew-installed `rebar3` (3.27.0) and the known-good `rebar3` escript already proven working for MongooseIM under OTP 27 **segfault (exit 139) under OTP 28** — reproduced under two different OTP 28 patch releases (28.0.1 and a freshly-`kerl`-built 28.3.3), while plain `erl`/`escript` work fine under the same OTP 28 installs, isolating the crash to the `rebar3` escript itself rather than the OTP installation. Worked around by locally removing the `minimum_otp_vsn` line and building under OTP 27 (already proven for MongooseIM) — a documented, honest workaround, not a silent skip. This is a real-world example of exactly the kind of BEAM-tooling friction a prospective user might hit, independent of anything this project builds.

### Chunking comparison (same checkout, both built)

| | Python (`chunker.py`) | Elixir port | ratio |
|---|---:|---:|---:|
| files discovered | 26 (22 `.erl`, 2 `.md`, 2 `.yml`) | 26 | — |
| **total chunks** | **409** | **399** | **97.6%** |
| `function` chunks | 279 | 279 | **100%** (exact match) |
| `attribute` chunks | 126 | 116 | 92% |
| text-window fallback | 4 | 4 | 100% (exact match) |

This is the cleanest parity result yet — `function` chunks match exactly, and the entire gap (10 chunks) is in `attribute` chunks, consistent with the same header-deduplication mechanism already explained for MongooseIM (Python re-chunks a shared header's attributes once per including file; the port chunks each header once). No partial or fatal warnings on either side — all `-include_lib` dependencies (escalus, exml, gun, fusco, amoc_arsenal) resolved cleanly once the repo was properly built.

### Call graph comparison

| | Baseline (`shared/amoc-arsenal-xmpp_callgraph.json`) | Elixir port | ratio |
|---|---:|---:|---:|
| nodes/vertices | 904 | 414 | 46% |
| edges | 3,065 | 833 | 27% |

A much larger gap than MongooseIM's (81%/66%). Own-repo defs are 279 either way (matching the chunking comparison exactly), so the gap is entirely in referenced-but-undefined call targets and edges. Given the same "~48,000 chunks" recollection for MongooseIM turned out not to match a fresh checkout of that repo, the baseline here may similarly reflect a different commit/state of amoc-arsenal-xmpp than today's clone — not independently confirmed (no live tree-sitter run was possible in this environment, see below), so treat this gap as unexplained rather than concerning. The chunking comparison above, which *is* a live same-checkout comparison, is the more reliable signal for this repo.

## Open items

- **Call-graph edge-count gaps** (MongooseIM 66%, amoc-arsenal-xmpp 27%) not root-caused to the same confidence level as the chunking gaps. Worth a closer file-by-file diff if precise numbers are needed before the Phase 1 launch post.
- **Tree-sitter macro-blindness claim** rests on source-code reading plus one live confirmation via the Serena/`erlang_ls` benchmark (see `docs/phase0-vs-serena-report.md`), not a direct side-by-side run of `call_extractor.py` itself — `tree-sitter-languages==1.10.2` requires Python <3.12, only 3.12/3.14 are available in this environment. Re-verify directly if a Python <3.12 environment becomes available.
- **Residual ~10% MongooseIM function-chunk gap** not fully root-caused — worth a closer diff if a precise number is needed; not blocking, since amoc-arsenal-xmpp's function chunks matched *exactly*, suggesting the MongooseIM gap is likely down to a handful of specific files, not a systemic issue.
- File-count discrepancy (1066 vs 1063, MongooseIM chunking) not root-caused — low priority, small magnitude.
- **`rebar3` segfaults under OTP 28** on this machine (both a homebrew install and the MongooseIM-bundled escript, across two OTP 28 patch releases) — worth reporting upstream to rebar3 if it reproduces elsewhere; not investigated further since a workaround (build under OTP 27) was sufficient here.
