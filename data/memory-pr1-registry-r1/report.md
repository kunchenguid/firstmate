# PR-1 Memory Registry Implementation Report

Task: memory-pr1-registry-r1.
Branch: fm/memory-pr1-registry-r1.
Date: 2026-07-14.

## Changed Files

- `memory/package.json`
- `memory/package-lock.json`
- `memory/.gitignore`
- `memory/bin/mem.mjs`
- `memory/shims/mem`
- `memory/scripts/install-shim.mjs`
- `memory/lib/activity.mjs`
- `memory/lib/cli.mjs`
- `memory/lib/doctor.mjs`
- `memory/lib/hash.mjs`
- `memory/lib/lock.mjs`
- `memory/lib/paths.mjs`
- `memory/lib/registry.mjs`
- `memory/lib/risk-class.mjs`
- `memory/lib/schema.mjs`
- `memory/test/cli-smoke.test.mjs`
- `memory/test/doctor.test.mjs`
- `memory/test/helpers.mjs`
- `memory/test/lock.test.mjs`
- `memory/test/recovery.test.mjs`
- `memory/test/registry.test.mjs`
- `memory/test/risk-class.test.mjs`
- `data/memory-pr1-registry-r1/report.md`

## Scope

This PR implements PR-1 only.
It adds the inert `memory/` package and does not wire current FirstMate workflow scripts to memory.
It does not implement PGlite FTS, vectors, migration, recall integration, session-pack generation, brief injection, spawn enforcement, teardown enforcement, Fleet Bridge UI, reconciliation, closeout gates, or graph work.

## Schema Summary

The canonical registry row schema is `kraken-memory/registry-event/v1`.
Registry events are `proposed`, `activated`, `updated`, `superseded`, `retired`, `quarantined`, `revalidated`, and `rejected`.
Projected statuses are `candidate`, `active`, `quarantined`, `superseded`, `retired`, and `rejected`.
Activation requires evidence and validation.
The active-memory index schema is `kraken-memory/active-index/v1`.
The active-memory index contains active records only, the registry watermark, and a per-record SHA-256 content hash.
The activity row schema is `kraken-memory/activity-event/v1`.
Recovery audit is recorded as `registry_recovered` in the activity ledger.

## CLI Commands

- `mem propose`
- `mem activate`
- `mem show`
- `mem update`
- `mem supersede`
- `mem retire`
- `mem quarantine`
- `mem audit`
- `mem project`
- `mem index rebuild`
- `mem snapshot`
- `mem recover`
- `mem doctor`
- `mem doctor --json`

## Paths

The package install path after land is `$HOME/fleet/firstmate-runtime/memory/`.
The committed shim is `memory/shims/mem`.
The installed shim target is `~/.local/bin/mem`.
The shim resolves only `MEM_CLI`, or `${FM_HOME:-$HOME/fleet/firstmate-runtime}/memory/bin/mem.mjs`.
The registry default path is `$HOME/fleet/state/memory/`.
Tests and write smoke use `MEM_REGISTRY_DIR`.

## Install Procedure

Run `cd $HOME/fleet/firstmate-runtime/memory && npm ci`.
Run `cd $HOME/fleet/firstmate-runtime/memory && npm run install-shim`.
Run `mem doctor`.
No dispatch path automatically installs dependencies.
Worktrees should call the pinned canonical shim rather than installing a per-worktree package.

## Rollback Procedure

Remove or stop using `~/.local/bin/mem`.
Revert the PR-1 commit or remove `$HOME/fleet/firstmate-runtime/memory/`.
Remove generated derived files under `$HOME/fleet/state/memory/` only if the Captain explicitly approves that cleanup.
No current workflow script consumes this package, so reverting PR-1 restores the prior workflow behavior.

## Automated Tests

Command: `cd memory && npm test`.
Result: pass.
Node version: v22.22.1.
Summary: 24 tests passed, 0 failed.
Coverage includes append and fold, schema validation, status transitions, locking, concurrent writers, stale lock recovery, idempotent duplicate event IDs, fsync/read-back validation, active index projection, watermark matching, content hashing, snapshots, non-active exclusion, canonical-preserving index rebuild, rewritten A20 recovery, A31 risk classification, A34 diagnostics, and `mem doctor --json`.
Carried m7 fixture coverage included tests 3-6, 8, 13, and 17 in PR-1 fixture form.
A7, A11, rewritten A20, A31, and A34 are named in test cases.

## Isolated Write-Path Smoke

Path used: `/tmp/mem-smoke-Y9kwld`.
The smoke ran `propose`, `activate`, `show --chain`, `snapshot`, `audit --json`, `quarantine`, `retire`, and `project`.
The final isolated audit before quarantine reported one active record and a current active index.
The isolated registry directory was deleted after capture.
No production registry path was used for write-path smoke.

## Canonical Non-Mutating Smoke

The canonical path `/home/prode/fleet/state/memory` was absent before smoke.
`node memory/bin/mem.mjs audit --json` was run without `MEM_REGISTRY_DIR`.
It reported `records.total: 0`, `records.active: 0`, registry watermark seq `0`, and active index status `missing`.
`node memory/bin/mem.mjs doctor` was run without `MEM_REGISTRY_DIR`.
It reported registry status `missing` and did not create production records.
`node memory/bin/mem.mjs doctor --json` was run without `MEM_REGISTRY_DIR`.
It reported required dependencies available, package lock current, PGlite not installed for current milestone, vector extension not installed for current milestone, and embedding provider not configured.
I did not run `mem project` against the absent production path from this disposable worktree because that would create files outside the worktree.

## Zero Production Records Proof

Before smoke, `/home/prode/fleet/state/memory` was absent.
Before smoke, `/home/prode/fleet/state/memory/memory-registry.jsonl` was absent.
Canonical `audit --json` reported zero total records and zero active records.
No production `propose`, `activate`, `update`, `supersede`, `retire`, or `quarantine` command was run.

## Recovery Evidence

The rewritten A20 test appends a valid event, appends an unterminated corrupt tail, verifies registry health `critical`, verifies reads continue through the one valid event, verifies mutations are refused, verifies canonical bytes are untouched before recovery, runs `mem recover` through the library path, verifies original backup and corrupt-byte sidecar are retained, verifies the repaired registry validates, verifies the active index is rebuilt, and verifies a `registry_recovered` activity event is written.
Recovery also refuses a healthy registry.
Recovery refuses while another writer owns the lock.
Index rebuild refuses a critical registry and preserves canonical bytes.

## Risk-Class Evidence

The classifier is versioned as `risk-rules/v1`.
Rules are deterministic and keyed on structured metadata.
All matching rules are evaluated and the highest minimum wins.
Memory registry, writer, schema, or activation-policy changes classify as `critical`.
Missing or ambiguous classification defaults to `critical`.
Unknown operation flags default to `critical`.
A31 verifies a task labeled routine that touches `memory/lib/schema.mjs` still classifies as `critical`.
A31 verifies downgrade to `standard` is refused without a Captain override token.

## Doctor Evidence

`mem doctor` passed in this worktree with required dependencies installed.
`mem doctor --json` returned stable JSON with CLI availability, canonical checkout, Node compatibility, package lock status, required dependencies, PGlite status, vector-extension status, embedding-provider status, registry path and status, and active-index status.
The missing `node_modules` fixture printed `mem: required dependencies missing (zod); fix: cd <path> && npm ci`.
The missing `node_modules` fixture did not print a Node module stack trace.

## Shim Evidence

The committed shim contains no `.fb-redesign`, Fleet Bridge, worktree, or candidate-path search.
Running `bash memory/shims/mem help` in this worktree attempted exactly `/home/prode/fleet/firstmate-runtime/memory/bin/mem.mjs` and printed the fix command.
The test override is `MEM_CLI`.

## Clean Install Evidence

A temporary clean copy was created at `/tmp/mem-clean-install-VVo7q9/memory`.
`npm ci` installed one dependency and found zero vulnerabilities.
`MEM_REGISTRY_DIR=/tmp/mem-clean-install-VVo7q9/registry node bin/mem.mjs doctor --json` returned `ok: true`.
The temporary clean copy was deleted.

## No Fleet Bridge Invocation

`rg` found no `.fb-redesign` or Fleet Bridge resolution path in executable package code.
Fleet Bridge appears only in provenance comments for ported ledger semantics and in negative tests that assert the shim does not invoke it.

## Known Limitations

PGlite FTS is intentionally not installed or implemented in PR-1.
Vector indexing is intentionally not installed or implemented in PR-1.
No migration tool is implemented in PR-1.
No workflow script consumes the memory system yet.
Canonical empty-index generation was not run against the absent production path from this disposable worktree to avoid creating files outside the worktree.

## Confirmation

No current FirstMate workflow script consumes the new memory system yet.
No production memory records were created.
