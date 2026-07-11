# Launch post draft — status: Phase 0 evidence, pre-Phase-1

This is a draft of the evidence-based launch content Part 3 of the plan calls for ("ship the evidence from Phase 0 as the launch content, not a separate blog post written later"). Two things to flag before this goes anywhere:

1. **No install instructions yet.** The plan's Part 3 assumes a working `mix igniter.install` exists day one of the post. It doesn't — that's Phase 1, not built. This draft is technical evidence a launch post would be built around, not the post itself; add the "try it" section once Phase 1 ships.
2. **No semantic search claim.** The original plan leaned on "semantic search finds things LSP-based tools miss" as a key differentiator. `search_code`/embeddings don't exist yet in this project — only chunking and the call graph have been built. Every claim below is restricted to what was actually measured. Don't add the semantic-search angle until it's real.

---

## Draft: Why we rebuilt BEAM code intelligence on the real compiler frontend, not tree-sitter

Most AI code-search tools — including the ones built specifically for BEAM languages — parse Erlang and Elixir with tree-sitter grammars. That's a reasonable default for most languages. It's a bad one for Erlang specifically, because Erlang has a real macro preprocessor (`epp`), and tree-sitter grammars operate on raw syntax — they see `?MACRO(...)` as an opaque token, never what it expands to. On a codebase that leans on macros for cross-cutting patterns (backend dispatch, logging wrappers, `-define`-based DSLs — all common in production OTP systems), that's not a rare edge case, it's a routine blind spot.

We rebuilt the chunking and call-graph layer of [project name] in pure Elixir, calling `:epp` and `Code.string_to_quoted/2` directly — the same frontends the compiler itself uses — instead of shelling out to a tree-sitter-based subprocess. Here's the evidence, measured against two real, large-ish production Erlang codebases (MongooseIM, an XMPP server; amoc-arsenal-xmpp, its load-testing counterpart), not toy examples.

### The macro-transparency claim, proven on real code

`ejabberd_ctl.erl` in MongooseIM defines:

```erlang
-define(PRINT(Format, Args), io:format(lists:flatten(Format), Args)).
```

used throughout the file, e.g. in `print_usage_command/3`. We ran the same question — "what does this function actually call?" — through our epp-based extractor and through an existing, well-regarded, free, MCP-native code-intelligence tool purpose-built for Elixir and Erlang, backed by a standard Erlang language server, against the identical file.

Our extractor: `io:format`, `lists:flatten` — the real targets, resolved because `:epp` expands the macro before we ever see the AST.

The existing tool: the raw, unexpanded `?PRINT([...], [])` text. The real call targets never appear anywhere in its output — a user would have to separately find the macro definition and mentally substitute it.

This isn't a synthetic example built to make a point — it's a macro already in production use in a real, actively-maintained XMPP server.

### Parity where it should be at parity

The point of building on the real compiler frontend isn't to be *different* for its own sake — it's to be at least as accurate as the existing tree-sitter-based approach everywhere, and better specifically where macros matter. We validated this by running the exact same real Python/tree-sitter pipeline against the exact same checkouts:

| Repo | Chunks (Python/tree-sitter) | Chunks (epp/AST) | Parity |
|---|---:|---:|---:|
| amoc-arsenal-xmpp (22 files) | 409 | 399 | **97.6%**, `function` chunks match *exactly* (279/279) |
| MongooseIM (843 files) | 30,966 | 25,315 | 82% |

The MongooseIM gap isn't unexplained noise: it's concentrated almost entirely in one specific, well-understood mechanism. The tree-sitter-based pipeline re-chunks a shared header's content once for *every file* that includes it (166 files include one commonly-shared header alone) — our version chunks each header exactly once, where it's actually defined. That's not a bug we're covering for; it's a deliberate fix that also happens to mean fewer near-duplicate, lower-quality chunks in whatever gets embedded downstream.

### Fast, for free

Because parsing each file is a pure, independent operation, indexing parallelizes with zero extra design work — `Task.async_stream` gets you there. Measured on MongooseIM's 1,063 files: 1.47s sequential → 0.57s at 8-way concurrency, with byte-identical output at every concurrency level (correctness isn't traded for speed).

### What this is not (yet)

- **Not a semantic search replacement.** We haven't built embedding-based search yet. If you need "how does session resumption work" style conceptual queries, neither this project nor other purpose-built Elixir/Erlang tooling can answer that today (the existing tool we compared against deliberately doesn't do embeddings either).
- **Not a claim that existing tools are bad.** Most of what didn't work well in our side-by-side wasn't an architectural limitation of LSP-based tools in general — it looked like a specific, fixable gap in that particular tool's current Erlang integration (its "find references" capability didn't return results for real, definitely-called functions, including same-file local calls — a bug, not a fundamental ceiling). The macro-transparency result is the one that's architectural: no LSP-based tool can show you a macro-expanded call target, regardless of how well-implemented it is, because that information doesn't exist until a compiler frontend expands it.

### Try it

*(Fill in once Phase 1's `mix igniter.install` exists.)*

---

## Sourcing notes (not for publication — for whoever finalizes this)

- Full technical detail and raw transcripts: `docs/phase0-parity-report.md`, `docs/phase0-vs-serena-report.md` (internal filenames only — do not carry the tool name from these filenames into public-facing copy).
- The `?PRINT` example is fully reproducible: `priv/fixtures/mongooseim/src/ejabberd_ctl.erl`, function `print_usage_command/3`.
- Concurrency numbers are from the pre-`_build` MongooseIM run (24,606 chunks baseline); re-verify against current numbers (25,315) before publishing if the gap matters for the specific claim being made.
- "166 files include one commonly-shared header" refers to `jlib.hrl` — verify this count is still current before publishing, since it depends on the MongooseIM commit checked out (`2d21164`).
- Real repo/library name (currently referred to as "[project name]" above) needs to be finalized before this ships — check whether "beamlens" (the working name used throughout this project) is the final call.
