# Firstmate portable test shards (Phase 4)

This document records how the two portable parallel CI shards were balanced from measured evidence.
Composition and execution are owned by `bin/fm-test-run.sh` (`--lane portable-parallel-1` / `portable-parallel-2` / `portable-serial`).
The proven-isolated candidate set remains owned by `bin/fm-test-isolation-proof.sh`.

## Inputs

| Input | Owner / source |
|---|---|
| Proven-isolated set (30 scripts) | `bin/fm-test-isolation-proof.sh --list` and `docs/fm-test-isolation-proof.md` |
| Phase 1 serial durations | CI timing artifacts `fm-test-timing` from main after #825 / #832 / #834 |
| Real-Herdr family | `bin/fm-test-run.sh --family real-herdr-gated` (dedicated required CI lane) |

Phase 1 averages used for balance (mean of available serial `duration_ms` across those artifacts):

| duration_ms (avg) | script |
|---:|---|
| 29639 | `tests/fm-arm-pretool-check.test.sh` |
| 25402 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 19428 | `tests/fm-x-mode.test.sh` |
| 14979 | `tests/fm-cd-pretool-check.test.sh` |
| 9339 | `tests/fm-backend-herdr.test.sh` |
| 6885 | `tests/fm-herdr-lab.test.sh` |
| 5127 | `tests/fm-crew-state.test.sh` |
| 4044 | `tests/fm-pr-merge.test.sh` |
| 3922 | `tests/fm-grok-harness.test.sh` |
| 2492 | `tests/fm-test-run.test.sh` |
| 1901 | `tests/fm-send-popup-settle.test.sh` |
| 1234 | `tests/fm-spawn-batch.test.sh` |
| 851 | `tests/fm-send-strict.test.sh` |
| 791 | `tests/fm-review-diff.test.sh` |
| 627 | `tests/fm-tmux-submit-busy.test.sh` |
| 525 | `tests/fm-brief.test.sh` |
| 321 | `tests/fm-composer-ghost.test.sh` |
| 283 | `tests/fm-dispatch-select.test.sh` |
| 276 | `tests/fm-send-settle.test.sh` |
| 189 | `tests/fm-ensure-agents-md.test.sh` |
| 175 | `tests/fm-supervision-instructions.test.sh` |
| 138 | `tests/fm-instruction-owners.test.sh` |
| 133 | `tests/fm-lint.test.sh` |
| 108 | `tests/fm-pi-primary-types.test.sh` |
| 106 | `tests/fm-nm-test-contract.test.sh` |
| 67 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-captain-translation-contract.test.sh` |
| 48 | `tests/fm-composer-lib.test.sh` |
| 36 | `tests/fm-stow-contract.test.sh` |
| 28 | `tests/fm-no-mistakes-ownership.test.sh` |

## Balancing method

Longest-processing-time (LPT) assignment onto two workers using the Phase 1 averages above.
Do not rebalance alphabetically or by family intuition.
Shard execution order is longest-first so wall-clock tracks the balanced sum.

| Lane | Script count | Sum of Phase 1 averages |
|---|---:|---:|
| `portable-parallel-1` | 15 | 64579 ms (~64.6 s) |
| `portable-parallel-2` | 15 | 64579 ms (~64.6 s) |
| imbalance | | 0 ms |

Exact ordered membership is the heredoc lists in `bin/fm-test-run.sh` (`list_portable_parallel_1` / `list_portable_parallel_2`).

## Portable serial remainder

`portable-serial` is every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
That keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in (default skip), GUI backends, and other stateful or unproven work serial.
Measured serial remainder wall (from the same Phase 1 artifacts, excluding Herdr) is about **13 minutes**.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` proves:

1. The two portable parallel shards are a partition of the proven-isolated set.
2. Proven-isolated embeds match `bin/fm-test-isolation-proof.sh --list`.
3. Union of portable parallel shards + portable serial + real-Herdr family equals the complete `tests/*.test.sh` inventory.
4. Those four partitions are pairwise disjoint (no missing scripts, no duplicates).

CI runs that guard as a required job (`test-coverage`).

## Timing artifacts

Every portable shard, the portable serial lane, and the Herdr lane upload their runner-generated timing JSON even when the behavior run reports failures.
The dependent aggregate job runs after all four lanes, combines every available lane JSON through `bin/fm-test-run.sh --aggregate-json`, and uploads one summary artifact for critical-path review.
The workflow in `.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | Measured shard sum ~1 min; hang tripwire with margin |
| portable serial | 20 | Measured ~13 min remainder; reduced from interim 25m full-portable slack after sharding |
| Herdr | 40 | Unchanged hang tripwire for the real-Herdr lane |

Timeouts remain hang tripwires, not expected healthy ends of green suites.
Do not raise them as a substitute for green results, retries, or weaker assertions.

## What this phase does not do

- Does not expand the proven-isolated set without a new concurrent isolation proof.
- Does not parallelize watcher, AFK, real Herdr, real tmux, or other stateful families.
- Does not start rollout verification; that waits until this PR is green and merged.
