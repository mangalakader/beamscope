# Phase 0.6 — Benchmark Questions: Elixir Spike vs. Serena

Scope note: per the plan, questions were meant to span 3 categories — (a) symbol-lookup, (b) conceptual/semantic, (c) macro/dynamic-dispatch edge cases. Category (b) is **not included**: the spike has no `search_code`/embedding pipeline yet (only chunking and the call graph have been built in Phase 0 so far), so conceptual queries aren't answerable on this side. This isn't an unfair asymmetry against Serena, though — Serena deliberately avoids embeddings by design too (see the market-validation research), so neither system can currently answer "how does session resumption work" style questions. Revisit this category once semantic search exists on the spike side.

All questions run against the same checkout: `priv/fixtures/mongooseim` (MongooseIM, commit `2d21164`, master, built via `rebar3 get-deps && rebar3 compile`).

## Category (a): symbol lookup

Serena should handle these fine via `erlang_ls`'s LSP features (definition, references, call hierarchy).

1. Where is `mod_offline_backend:pop_messages/2` defined?
2. What calls `mongoose_backend:call_tracked/4`?
3. What functions does `mod_offline_backend:init/2` call?
4. Find all callers of `gen_mod:get_module_opt/4` (widely used utility function).
5. What is the call path (if any) from `mod_offline_backend:init/2` to `mongoose_backend:init/4`?
6. Where is `mongoose_backend:get_backend_module/2` defined, and what calls it?

## Category (c): macro / dynamic-dispatch edge cases

These specifically probe the claim from the market-validation research: LSP-based tools should struggle where macro expansion or dynamic dispatch hides the real target, while an epp/AST-based approach that sees fully-expanded forms should not (for macro cases — genuinely runtime-computed dispatch is out of reach for *both* approaches, and is included here as an honest shared-limitation control question, not a differentiator).

7. **(real code, not synthetic)** `ejabberd_ctl.erl` defines `-define(PRINT(Format, Args), io:format(lists:flatten(Format), Args))`. What does `ejabberd_ctl:print_usage_command/2` actually call, once `?PRINT(...)` is expanded?
8. **(synthetic fixture)** In `mod_fake_backend.erl`, `-define(BACKEND_MODULE(Host), gen_mod:get_module_opt(Host, ?MODULE, backend, mnesia))`. What does `mod_fake_backend:get_user/2` call?
9. **(shared limitation control)** `mod_offline_backend:pop_messages/2` calls `mongoose_backend:call_tracked/4`, which dispatches via `erlang:apply(BackendModule, FunName, Args)` where `BackendModule` is resolved at runtime from `persistent_term` (set during `init/2` based on config, e.g. to `mod_offline_mnesia` or `mod_offline_rdbms`). Does either system show `mod_offline_mnesia:pop_messages/2` as being called anywhere? (Expected honest answer from both: no static call exists — this is genuinely unresolvable without semantic/config-aware analysis, not a tooling gap.)
10. Within `mod_fake_backend.erl`, `Backend:get_user(Host, UserId)` calls through a variable bound by the macro-expanded `get_module_opt` call. Can either system identify this as unresolvable dynamic dispatch (vs. silently missing it entirely or misattributing it)?

## Scoring rubric

For each question, per system:
- **Pass** — found the correct location/answer with no missing information a human would need.
- **Partial** — found *something* relevant but missed a piece (e.g., found the call site but not the macro-expanded target).
- **Fail** — found nothing, found the wrong answer, or silently missed the call entirely without any indication something was skipped.

Raw output for both systems is captured in `docs/phase0-vs-serena-report.md`.
