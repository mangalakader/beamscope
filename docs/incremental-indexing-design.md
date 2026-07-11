# Incremental Indexing — Design Exploration (not implemented)

Two separable questions: (1) can re-indexing skip unchanged files, and (2) what triggers a re-index. Only (1) is buildable inside `beamlens_spike` today; both trigger mechanisms for (2) need something the spike doesn't have yet.

## 1. Manifest-based incremental core (buildable now, no new dependency)

Mirrors `manifest.py`'s role in the original Python pipeline — it's a **change detector**, not a data store. The important nuance: `manifest.py` doesn't cache chunk *content*, only file hashes; the actual chunks live in Qdrant, which is what makes "skip unchanged files" meaningful (Qdrant already has last run's chunks for that file, untouched). `beamlens_spike` has no persistent chunk store yet (no Qdrant wiring exists in Phase 0), so a manifest here can only produce a **delta**, not a merged result — the caller (eventually, Qdrant upsert/delete calls in Phase 1+) is responsible for applying it.

Design:
- `Manifest.load(path)` / `Manifest.save(path, hashes)` — a JSON file, `%{relative_path => sha256_hex}`, written atomically (temp file + rename, matching `manifest.py`'s `os.replace` pattern).
- `Pipeline.chunk_repo_incremental(repo_path, manifest_path, opts)` returns a delta, not a flat chunk list:
  ```elixir
  %{
    added: [%{path: ..., chunks: [...]}],      # new files
    changed: [%{path: ..., chunks: [...]}],    # content hash differs from manifest
    removed: [path, ...],                      # in manifest, gone from disk
    unchanged_count: n
  }
  ```
- Implementation is a thin wrapper around the existing `Pipeline.chunk_repo`/`Callgraph.Pipeline.extract_repo`: walk the repo, hash each file, diff against the loaded manifest, only call the chunker/extractor for added+changed paths, write the new manifest.
- Chunking and call-graph would need **separate manifests** (matching `build_index.py`/`build_callgraph.py` maintaining separate manifest files today) since they're independent pipelines with different downstream consumers.
- Cost: purely CPU-time savings on the parse step for a repo that hasn't changed much. No new dependency, no running process — just a hashing/diffing layer.

## 2a. Trigger: file-system watching (buildable, but a real feature addition)

- Needs the `file_system` Hex package — the standard choice in the Elixir ecosystem (FSEvents/inotify/ReadDirectoryChangesW wrapper; this is what Phoenix's live-reload uses).
- A `Watcher` GenServer, started explicitly per repo (not auto-started for every repo by default):
  - Subscribes to `file_system` events for the repo directory, recursively.
  - **Must debounce**: a single save can fire multiple raw FS events (editors often write-to-temp-then-rename; `git checkout` touches many files at once). A ~500ms–1s quiet window before triggering is the standard pattern.
  - Filters events to chunkable extensions + `SKIP_DIRS`, reusing `Pipeline`'s existing filtering logic.
  - On debounce expiry, calls the incremental core from (1) — and can pass the *specific changed paths* `file_system` already reported, skipping the full-repo hash-walk entirely (though re-verifying via hash is still worth it, since `file_system` can report spurious/duplicate events).
  - Would need a supervision-tree entry in `BeamlensSpike.Application` (currently minimal) — likely a `DynamicSupervisor` so watchers can be started/stopped per repo rather than one static child.

## 2b. Trigger: "on recompile" (not buildable in the spike today)

This only has a meaningful hook point once `beamlens_spike`'s logic is packaged as a real, installed library inside a **target** project — and critically, **the two ecosystems this tool targets need two different hook mechanisms**:

- **Mix-based target projects**: a custom `Mix.Task.Compiler` module, registered via `compilers: [:beamlens] ++ Mix.compilers()` in the target's `mix.exs` (which an Igniter installer would add automatically). Runs on every `mix compile`, calls the incremental core, no-ops fast when nothing changed.
- **rebar3-based target projects** — and this matters a lot, because **MongooseIM and amoc-arsenal-xmpp, the two repos this whole project is validated against, are both rebar3, not Mix**: rebar3 has its own provider/plugin system (a `post_compile` hook registered in the target's `rebar.config`), which is a separate integration surface, likely needing a small Erlang-callable plugin package rather than anything Mix-compiler-shaped.

Worth flagging now rather than discovering later: "hook into recompile" for the primary target audience of this tool means building and maintaining a rebar3 plugin, not (only) a Mix compiler — a real scoping input for Phase 1 packaging decisions, not just an implementation detail.

## Recommended sequencing (not started)

1. Manifest-based incremental core (1) — cheap, no new dependency, immediately useful for the existing `Pipeline`/`Callgraph.Pipeline` even without any trigger mechanism (e.g. a person manually re-running indexing after `git pull`).
2. File-watching (2a) — once there's a real reason to want live re-indexing during active development, not speculatively.
3. rebar3/Mix compiler hooks (2b) — Phase 1+ packaging work, gated on Igniter installer design, and needs the rebar3 plugin built specifically because the target repos are rebar3 projects.
