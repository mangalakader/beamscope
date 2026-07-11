# Phase 0.6 — Elixir Spike vs. Serena

Both systems tested against the same checkout: `priv/fixtures/mongooseim` (MongooseIM, commit `2d21164`, master, built via `rebar3 get-deps && rebar3 compile`). Scope: categories (a) symbol-lookup and (c) macro/dynamic-dispatch only — see `docs/phase0-benchmark-questions.md` for why category (b), conceptual/semantic search, isn't tested on either side yet.

## Setup findings (a finding in themselves, per the plan)

- **Serena's `git+https://github.com/oraios/serena` (unreleased `main` branch) crashes immediately on Erlang**: `TypeError: Can't instantiate abstract class ErlangLanguageServer without an implementation for abstract method '_create_base_initialize_params'`. This is a real bug in Serena's own code, not an environment issue here — confirmed by then testing the stable PyPI release (`serena-agent==1.5.3`), where it doesn't occur. **The benchmark below uses the stable 1.5.3 release**, which is what anyone `pip install`-ing or `uvx`-ing Serena today would actually get — the git-main crash is noted for Serena's maintainers' benefit, not held against the product.
- With the stable release, `erlang_ls` (already installed at `/usr/local/bin/erlang_ls`, v0.52.0) starts and indexes MongooseIM's 694 application + 843 dependency + 947 OTP modules in ~6 seconds — fast, no complaints there.
- Elixir support uses a newer language server called **"Expert"** (v0.1.0-rc.6), not ElixirLS as the original plan assumed — Serena auto-downloaded a static binary for it. Since MongooseIM has zero `.ex`/`.exs` files (it's 100% Erlang, no `mix.exs` anywhere), Expert has nothing to index but still consumes up to its full 300-second startup budget waiting to compile/index a non-existent Elixir project — a real latency cost for a pure-Erlang repo with no way to disable it short of not requesting the `elixir` language at project-creation time.
- Indexing failed on 20 of 843 files (`.serena/logs/indexing.txt`) — `erlang_ls`'s own parser (`erlfmt_scan`) crashes with a `function_clause` error on at least `test/mod_caps_SUITE.erl`, `escalus_stanza.erl`, `escalus.erl`, `meck.erl`. This is an `erlang_ls`-side parser limitation, not a Serena integration issue — but it means those 20 files are simply invisible to Serena's symbol index, silently.
- Total setup time: ~15 minutes, mostly spent diagnosing the git-main crash and correcting `uvx`/language-server assumptions — nontrivial but not a dealbreaker, consistent with what the plan asked to report either way.

## Results

| # | Question | Spike | Serena | Notes |
|---|---|---|---|---|
| 1 | Where is `mod_offline_backend:pop_messages/2` defined? | **Pass** | **Pass** | Line numbers match exactly once accounting for LSP's 0-indexed vs. the spike's 1-indexed lines (51–53 vs. 52–54). |
| 2 | What calls `mongoose_backend:call_tracked/4`? | **Pass** (50 callers) | **Fail** | `find_referencing_symbols` returned `Error: No symbol matching 'call_tracked/4' found` despite the symbol definitely existing and being definitely called (confirmed by the spike). |
| 3 | What does `mod_offline_backend:init/2` call? | **Pass** | **Pass** | Serena's raw body text shows `mongoose_backend:init(...)` / `mongoose_backend:call(...)` directly — readable here because neither call target is itself macro-obscured (`?MAIN_MODULE`/`?FUNCTION_NAME` are argument *values*, not part of the callee). |
| 4 | Callers of `gen_mod:get_module_opt/4`? | **Pass** (97 callers) | **Fail** | Same `find_referencing_symbols` failure as Q2. |
| 5 | Call path `mod_offline_backend:init` → `mongoose_backend:init`? | **Pass** (direct edge) | **Fail (no such tool)** | Serena's tool list has no shortest-path/call-path capability at all — not a bug, a capability gap. |
| 6 | `mongoose_backend:get_backend_module/2`: definition + callers? | **Pass** (def + 4 callers) | **Partial** | Definition found correctly (`find_symbol`); callers lookup failed the same way as Q2/Q4. |
| 7 | What does `ejabberd_ctl:print_usage_command/2` call, via the real `?PRINT` macro? | **Pass** (`io:format`, `lists:flatten`) | **Fail** | This is the core differentiator claim, confirmed live: Serena's `find_symbol(include_body=True)` returns the **raw, unexpanded** `?PRINT([...], [])` text. It never reveals `io:format`/`lists:flatten` as the actual call targets — a user would have to separately find the `-define(PRINT(...), io:format(lists:flatten(Format), Args))` and mentally substitute it. |
| 8 | `mod_fake_backend:get_user/2` via `?BACKEND_MODULE` macro (synthetic fixture) | **Pass** | *Not independently tested* — fixture is outside the registered project scope; Q7 already demonstrates the same claim on real production code. |
| 9 | Does `mod_offline_mnesia:pop_messages/2` show any callers? (shared-limitation control — dispatch is via `erlang:apply` at runtime, genuinely unresolvable statically by *either* system) | **Pass** (honest empty list) | **Inconclusive** | Errored via the same `find_referencing_symbols` failure rather than returning an honest "no references found" — can't distinguish "correctly zero" from "tool broken" here. |
| 10 | Is `Backend:get_user(...)` correctly flagged as unresolvable dynamic dispatch? (synthetic fixture) | **Pass** (`callee_module: "?"`) | *Not independently tested* — same scope reason as Q8. |

**Tally (8 independently-testable questions, excluding 8/10):** Spike 8/8 pass. Serena: 2 pass, 1 partial, 4 fail, 1 inconclusive.

## Important caveat on the Serena score

The dominant failure mode above — `find_referencing_symbols` returning "No symbol matching" for real, called functions — reproduced even on a **same-file local call** (`backend_module/2`, called from `init/4` two lines away in the same file), ruling out a cross-file/remote-call-specific explanation. This looks like a genuine bug or gap in Serena's `erlang_ls` integration for the "references" capability specifically, not evidence that LSP-based call-hierarchy lookups are impossible in principle — `erlang_ls` itself advertises `callHierarchyProvider: true` in its LSP capabilities (visible in the startup log), so the underlying language server likely *can* do this; Serena's wrapper around it apparently doesn't invoke it successfully for Erlang. **The honest framing for a launch post is "Serena's current Erlang integration doesn't deliver on caller-lookup" — not "LSP-based tools structurally cannot find callers."** The macro-transparency result (Q7) is the one that's architectural, not incidental: no LSP-based tool, working or not, can show you a macro-expanded call target, because that information doesn't exist until the compiler frontend expands it — which is exactly what `:epp` does and tree-sitter/LSP symbol indexes do not.

## Raw transcripts

### Spike (via `Callgraph.Pipeline`/`Graph`, `iex -S mix` equivalent)

```
Q1: %{module: "mod_offline_backend", name: "pop_messages", start_line: 52, end_line: 54,
     file_path: ".../src/offline/mod_offline_backend.erl"}

Q2 (callers of mongoose_backend:call_tracked/4): 50 results, e.g.
["mod_pubsub_old_db_backend:set_node", "mod_roster_backend:update_roster_t",
 "mod_muc_backend:store_room", "mod_offline_backend:write_messages", ...]

Q3 (callees of mod_offline_backend:init/2): ["mongoose_backend:init", "mongoose_backend:call"]

Q4 (callers of gen_mod:get_module_opt/4): 97 results, e.g.
["mod_roster:roster_versioning_enabled", "mod_vcard:get_results_limit",
 "mod_register:try_register", "mod_disco:get_extra_domains", ...]

Q5 (shortest path init -> init): ["mod_offline_backend:init", "mongoose_backend:init"]

Q6: def at mongoose_backend.erl:72-74; callers:
["mongoose_backend:is_exported", "mongoose_backend:call_tracked", "ejabberd_sm:sm_backend",
 "mongoose_backend:call"]

Q7 (callees of ejabberd_ctl:print_usage_command/2, real ?PRINT macro):
["ejabberd_ctl:print_usage_commands", "io:format", "lists:flatten",
 "mongoose_graphql_commands:wrap_type", "ejabberd_ctl:binary_to_list",
 "ejabberd_ctl:get_shell_info"]

Q8 (callees of mod_fake_backend:get_user/2, synthetic ?BACKEND_MODULE macro):
["gen_mod:get_module_opt", "?:get_user"]

Q9 (callers of mod_offline_mnesia:pop_messages/2): []

Q10 (dynamic-dispatch edges in mod_fake_backend.erl):
[%{caller_name: "save_user", callee_module: "?", callee_name: "save_user", line: 25},
 %{caller_name: "get_user", callee_module: "?", callee_name: "get_user", line: 20}]
```

### Serena (`serena-agent==1.5.3`, streamable-http MCP, `erlang_ls` v0.52.0)

```
Q1: [{"name_path": "pop_messages/2", "kind": "Function",
      "relative_path": "src/offline/mod_offline_backend.erl",
      "body_location": {"start_line": 51, "end_line": 53}}]

Q2: Error executing tool: ValueError - No symbol matching 'call_tracked/4' found

Q3: [{"name_path": "init/2", ...,
      "body": "init(HostType, Opts) ->\n    mongoose_backend:init(HostType, ?MAIN_MODULE,
      [pop_messages, write_messages], Opts),\n    Args = [HostType, Opts],\n
      mongoose_backend:call(HostType, ?MAIN_MODULE, ?FUNCTION_NAME, Args)."}]

Q4: Error executing tool: ValueError - No symbol matching 'get_module_opt/4' found

Q5: (no shortest-path/call-path tool exists in Serena's tool list)

Q6: [{"name_path": "get_backend_module/2", ..., "body_location": {"start_line": 71, "end_line": 73}}]
    Error executing tool: ValueError - No symbol matching 'get_backend_module/2' found

Q7: [{"name_path": "print_usage_commands/3", ...,
      "body": "...\n    FmtCmdDescs = format_command_lines(...),\n    ?PRINT([FmtCmdDescs], [])."},
     {"name_path": "print_usage_command/3", ...,
      "body": "print_usage_command(Category, Command, ArgsSpec) ->\n    {MaxC, ShCode} = get_shell_info(),\n
      ?PRINT([\"Usage: \", ...], []),\n    ...\n    print_usage_commands(MaxC, ShCode, Args),\n
      ?PRINT([\"\\nScalar values do not need quoting...\"], [])."}]
      (?PRINT never expanded to io:format/lists:flatten anywhere in the output)

Q9: Error executing tool: ValueError - No symbol matching 'pop_messages/2' found

Control (same-file local call, backend_module/2 called by init/4 two lines away):
Error executing tool: ValueError - No symbol matching 'backend_module/2' found
```

## Honest summary for a launch post

- **Macro transparency (the core architectural claim) holds up under a live, real-code test**, not just source-reading inference: Serena/`erlang_ls` shows the raw `?PRINT(...)` macro call and never reveals the real `io:format`/`lists:flatten` targets; the epp-based extractor resolves them correctly, on the same real file, same real macro, in production MongooseIM code (not a contrived example).
- **Symbol lookup (definition-finding) is roughly at parity** — both systems found the right file and line for every definition question tested.
- **Caller-lookup (`find_referencing_symbols`) failed across the board in this Serena+erlang_ls setup**, including for a same-file local call — this reads as a real bug/gap in Serena's current Erlang integration rather than a fundamental limitation of LSP-based approaches in general, and should be framed that way rather than oversold as "LSP tools can't find callers."
- **Serena has no call-path/shortest-path tool at all** — a capability gap, not a bug.
- **Setup friction was real but not severe**: ~15 minutes, dominated by a git-main regression (irrelevant to the stable release) and correcting assumptions about which language server Elixir uses.
