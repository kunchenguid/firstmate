# Firstmate test isolation proof (Phase 2)

This document is the archived concurrent isolation proof for the portable parallel candidate set.
It is the human-readable companion to `bin/fm-test-isolation-proof.sh`.
Production CI sharding and general local `fm-test-run.sh --jobs` remain **off** until a later phase explicitly enables them.

## Owner

- Harness: `bin/fm-test-isolation-proof.sh`
- Contract tests: `tests/fm-test-isolation-proof.test.sh`
- Family labels (Phase 1): `bin/fm-test-run.sh`
- Timing evidence used for planning: CI artifact `fm-test-timing` from Phase 1 PR #825

## Proof posture

| Field | Value |
|---|---|
| `run_id` | `fm-isolation-1784693155237-99474` |
| `started_at` | `2026-07-22T04:05:55Z` |
| `finished_at` | `2026-07-22T04:08:06Z` |
| concurrency | **4** |
| candidates | **30** |
| failed | **0** |
| wall duration_ms | **131001** (~131.0s) |
| `production_sharding_enabled` | `False` |
| `fm_test_run_jobs_enabled` | `False` |
| host proof date | 2026-07-22 (UTC day of archive write) |

Isolation checks that passed with this run:

- Distinct mode-`0700` temporary roots per worker under a proof-owned parent
- Per-worker `TMPDIR`/`TMP` so `mktemp` / `fm_test_tmproot` stay private
- Ambient `FM_HOME` / `FM_*_OVERRIDE` cleared for each worker
- `git config --global` snapshot unchanged before/after the matrix
- Aggregate failure reporting (any non-zero candidate fails the harness; no retry-until-green)

## Exact candidate set

Sorted paths as selected by `bin/fm-test-isolation-proof.sh --list` at proof time:

- `tests/fm-arm-pretool-check.test.sh`
- `tests/fm-backend-herdr.test.sh`
- `tests/fm-brief.test.sh`
- `tests/fm-captain-translation-contract.test.sh`
- `tests/fm-cd-pretool-check.test.sh`
- `tests/fm-composer-ghost.test.sh`
- `tests/fm-composer-lib.test.sh`
- `tests/fm-crew-state.test.sh`
- `tests/fm-decision-hold-lifecycle.test.sh`
- `tests/fm-dispatch-select.test.sh`
- `tests/fm-ensure-agents-md.test.sh`
- `tests/fm-grok-harness.test.sh`
- `tests/fm-herdr-lab.test.sh`
- `tests/fm-instruction-owners.test.sh`
- `tests/fm-lint.test.sh`
- `tests/fm-nm-test-contract.test.sh`
- `tests/fm-no-mistakes-ownership.test.sh`
- `tests/fm-pi-primary-types.test.sh`
- `tests/fm-pr-merge.test.sh`
- `tests/fm-review-diff.test.sh`
- `tests/fm-send-popup-settle.test.sh`
- `tests/fm-send-settle.test.sh`
- `tests/fm-send-strict.test.sh`
- `tests/fm-spawn-batch.test.sh`
- `tests/fm-stow-contract.test.sh`
- `tests/fm-supervision-instructions.test.sh`
- `tests/fm-test-run.test.sh`
- `tests/fm-tmux-submit-busy.test.sh`
- `tests/fm-transition-lib.test.sh`
- `tests/fm-x-mode.test.sh`

## Per-candidate durations (concurrent run)

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 38449 | 0 | 30 | `tests/fm-x-mode.test.sh` |
| 35417 | 0 | 2 | `tests/fm-backend-herdr.test.sh` |
| 29102 | 0 | 1 | `tests/fm-arm-pretool-check.test.sh` |
| 21133 | 0 | 9 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19896 | 0 | 8 | `tests/fm-crew-state.test.sh` |
| 18610 | 0 | 5 | `tests/fm-cd-pretool-check.test.sh` |
| 12517 | 0 | 13 | `tests/fm-herdr-lab.test.sh` |
| 8939 | 0 | 19 | `tests/fm-pr-merge.test.sh` |
| 6953 | 0 | 21 | `tests/fm-send-popup-settle.test.sh` |
| 5963 | 0 | 12 | `tests/fm-grok-harness.test.sh` |
| 4645 | 0 | 27 | `tests/fm-test-run.test.sh` |
| 3524 | 0 | 22 | `tests/fm-send-settle.test.sh` |
| 2803 | 0 | 6 | `tests/fm-composer-ghost.test.sh` |
| 2552 | 0 | 28 | `tests/fm-tmux-submit-busy.test.sh` |
| 2549 | 0 | 20 | `tests/fm-review-diff.test.sh` |
| 1551 | 0 | 23 | `tests/fm-send-strict.test.sh` |
| 1274 | 0 | 15 | `tests/fm-lint.test.sh` |
| 1056 | 0 | 18 | `tests/fm-pi-primary-types.test.sh` |
| 897 | 0 | 3 | `tests/fm-brief.test.sh` |
| 874 | 0 | 10 | `tests/fm-dispatch-select.test.sh` |
| 684 | 0 | 24 | `tests/fm-spawn-batch.test.sh` |
| 348 | 0 | 11 | `tests/fm-ensure-agents-md.test.sh` |
| 283 | 0 | 26 | `tests/fm-supervision-instructions.test.sh` |
| 232 | 0 | 14 | `tests/fm-instruction-owners.test.sh` |
| 201 | 0 | 16 | `tests/fm-nm-test-contract.test.sh` |
| 104 | 0 | 29 | `tests/fm-transition-lib.test.sh` |
| 90 | 0 | 4 | `tests/fm-captain-translation-contract.test.sh` |
| 68 | 0 | 7 | `tests/fm-composer-lib.test.sh` |
| 57 | 0 | 25 | `tests/fm-stow-contract.test.sh` |
| 36 | 0 | 17 | `tests/fm-no-mistakes-ownership.test.sh` |

## Audit notes (why this set)

Source families from the Phase 1 manifest and scout report §3.1:

1. **pure-contract-unit** candidates audited from the Phase 1 family manifest, minus deliberate serial exclusions
2. **Extra hermetic candidates** after static audit: fake backend, private git fixtures, stubbed network

The harness pins this exact archived set and does not automatically admit later family additions.
A candidate-set change requires a new audit and concurrent proof archive.

### Included extras (beyond pure-contract-unit)

| Script | Why included |
|---|---|
| `tests/fm-backend-herdr.test.sh` | Fake Herdr CLI + private temps; no real Herdr binary |
| `tests/fm-send-strict.test.sh` | Fake tmux PATH shim; private `FM_HOME` |
| `tests/fm-spawn-batch.test.sh` | Argument routing only; no real windows/worktrees |
| `tests/fm-pr-merge.test.sh` | Fake `gh`/`gh-axi`; private state |
| `tests/fm-review-diff.test.sh` | Local git fixtures via `fm_git_*`; no live forge |
| `tests/fm-x-mode.test.sh` | Fake `curl`; inert without token |

### Deliberately serial (kept out of this pool)

Run `bin/fm-test-isolation-proof.sh --list-exclusions` for the machine-readable list.
High-signal classes:

| Class | Examples | Reason |
|---|---|---|
| Process-holder pure unit | `fm-continuity-pretool-check` | Background `sleep 300` lock-holder process |
| Watcher / wake / locks | `fm-watcher-lock`, `fm-wake-queue`, ... | Intentional process locks and daemon races |
| AFK | `fm-afk-inject-e2e`, ... | Daemon lifecycle and inject path |
| Real Herdr | `fm-backend-herdr-smoke`, presentation e2e, ... | Named labs, session-global locks; Herdr lane is Phase 3+ |
| Real tmux smoke | `fm-backend-tmux-smoke` | Real multiplexer server (even on private socket) |
| Live harness opt-in | `fm-*-live-e2e` | Real interactive agents |
| GUI backends | cmux smoke | Shared GUI app |
| Gray-zone git/spawn | `fm-backend`, spawn settle/profile, teardown | Heavier worktree or lock-race matrices |
| Watcher-adjacent forge security | `fm-pr-check-security` | `.watch.lock` / poll security surface |
| Self | `fm-test-isolation-proof.test.sh` | Must not re-enter the concurrent matrix |

### Small isolation fix landed with this phase

`tests/fm-arm-pretool-check.test.sh` no longer writes Claude deny stderr to a fixed `/tmp/fm-arm-pretool-check-claude-stderr.$$` path.
It uses `mktemp` under `TMPDIR` so concurrent workers cannot collide on a global temp name pattern.

## Failures

None.
Every candidate exited 0 under concurrency=4.

Policy: a script that fails only under concurrency is **removed** from the candidate set and investigated.
It is never retried into green, skipped more broadly, or weakened in assertions.

## What this phase does not do

- No production CI Behavior matrix / shard jobs
- No `bin/fm-test-run.sh --jobs`
- No Herdr install lane (Phase 3+)
- No complete-suite local re-run as part of this proof (focused matrix only)

## How to re-run

```sh
bin/fm-test-isolation-proof.sh --list
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json
bash tests/fm-test-isolation-proof.test.sh
```
