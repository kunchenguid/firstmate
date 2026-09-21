# Memory store

Durable agent memory is plain markdown under a per-home store directory, searched by a light length-normalized BM25 index.
This page owns the operator contract: store layout, the migration out of OpenViking, the retirement of the old server, and rollback.
Each script's header and `--help` own exact flags and exit codes; this page states the shape and the invariants.

The arrangement exists because the captain chose it on 2026-09-20 after the `data/memory-store-reliable-cheap` investigation: the OpenViking server burned about 9.5% of a core in a non-converging retry loop against a dead Ollama, while the memory payload itself was about 119 markdown files.
Vector recall, session auto-ingest, and vikingbot were deliberately traded away; what remains is files plus keyword search, with no daemon, no model backend, and no GPU.

## Layout

The store defaults to `$FM_HOME/data/memories`; [`configuration.md`](configuration.md#memory-store-configmemory-dir) owns the `FM_MEMORY_DIR` and gitignored `config/memory-dir` overrides and their precedence.
Every home has its own store; `config/memory-dir` is home-local and is not part of secondmate inherited configuration.
A memory is one markdown file `<category>/<topic>.md` written by `remember` with a small frontmatter block (`category`, `created`, `updated`) and a `# <topic>` title.
The OpenViking categories carry over: `preferences`, `entities`, `events`; `remember` normalizes the singular names.
The BM25 index is `<store>/.index.json`, a disposable cache owned by [`bin/fm-memory-bm25.mjs`](../bin/fm-memory-bm25.mjs) that self-rebuilds whenever the tree drifts from its recorded manifest, so recall never answers from stale bytes.
Recall scores the title and body only: the frontmatter block stays structured metadata and is never indexed, so a metadata word or a date is not a ranking signal.
Session history and other non-memory markdown migrate to `$FM_HOME/data/memory-archive/` rather than into the searchable store.

## Commands

- `bin/fm-memory.sh remember [--category <cat>] <topic> [body...]` writes or updates a memory; the body may come from stdin.
- `bin/fm-memory.sh recall [--json] [--limit <n>] <query>` ranks memories by BM25; `--json` emits one envelope for programmatic consumers such as a recall-injection hook.
- `bin/fm-memory.sh list`, `stats`, `dir`, and `reindex` inspect the store and manage the index.

## Migrating from OpenViking

Run [`bin/fm-memory-migrate.sh`](../bin/fm-memory-migrate.sh) on the machine that holds the OpenViking workspace:

```sh
bin/fm-memory-migrate.sh migrate                # copies, verifies, reindexes
bin/fm-memory-migrate.sh migrate --dry-run      # prints the plan only
bin/fm-memory-migrate.sh verify                 # re-checks every destination hash
```

The memories tree is located under `--source` (default `$FM_OV_HOME/data`, `FM_OV_HOME` defaulting to `~/.openviking`) by the probe order in the script header, or pinned directly with `--memories-dir`.
All remaining markdown under the source - sessions, wiki-layer, resources, skills - lands in the archive directory, while `_system/`, `vectordb/`, and `logs/` are deliberately skipped.
Each run writes a manifest under `<store>/.migration/` pairing every exported source file with its sha256, and verifies destination hashes before reporting success; the script never writes to the source and never deletes from the destination. A re-run restores a missing copy and refreshes a destination the last migration wrote that still matches its recorded hash; any other destination that already exists - including one the migration never wrote, or one the newest manifest carries no row for - is left untouched and reported as skipped-and-kept, so operator edits are never overwritten.

## Retiring the server

Run [`bin/fm-openviking-retire.sh`](../bin/fm-openviking-retire.sh) on the OpenViking host after a verified migration.
It boots out and disables every launchd label containing "viking", SIGTERMs a residual `openviking-server`, rotates the unrotated logs under `~/.openviking/logs/` to timestamped names, and verifies nothing answers on the API port.
`--dry-run` narrates the sequence without touching anything.
The `~/.openviking/data` tree is never deleted; rollback is the printed `launchctl enable` + `bootstrap` pair per label, and the store keeps working because nothing in the new path depends on the server.
A nix or home-manager rebuild can reinstall the plist - remove the `openviking` module there for permanence.

Standing check carried over from the investigation: after any backend change, confirm the OpenViking queue is empty (`ov status`) before trusting that the retry burn is gone.

## Operator steps outside this repo

The repo ships the store and its commands; three pieces of the old path live outside it and are repointed by hand:

- `~/.local/bin/ov-remember`: `exec <repo>/bin/fm-memory.sh remember "$@"` is not a drop-in for the old argument order; translate each old form by hand:
  - `ov-remember <topic> "<fact>"` -> `fm-memory.sh remember <topic> "<fact>"`
  - `ov-remember <topic> "<fact>" --category entity` -> `fm-memory.sh remember --category entity <topic> "<fact>"`; `--category` must come before the topic.
  - `ov-remember <topic> --from-file <path>` -> `fm-memory.sh remember <topic> < <path>`; there is no `--from-file`, the body comes from arguments or stdin.
  - `ov-remember --list` -> `fm-memory.sh list`
  An option left after the body (`--category ...`, `--from-file ...`) now exits non-zero instead of being stored as the fact.
- The `~/.claude/CLAUDE.md` durable-memory section: point recall at `bin/fm-memory.sh recall` and writes at `bin/fm-memory.sh remember` in place of `ov find` and `ov-remember`.
- The Pi extension's recall injection: call `bin/fm-memory.sh recall --json <query>` where it previously called `viking_search`; session-commit shipping is gone by design.

Secondmates resolve the same commands against their own `$FM_HOME`; nothing is shared or synced between stores unless the operator makes it so.

## What is intentionally absent

No vector embeddings, no semantic similarity beyond keyword BM25, no session-archive ingestion, no vikingbot, and no model backend of any kind.
Adding any of those back is a new decision, not a repair.
