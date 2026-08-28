# Firstmate test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/fm-test-isolation-proof.sh` is the authoritative harness and `docs/fm-test-isolation-proof.json` is the machine-readable result.
`bin/fm-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-08-20
- Command: `bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json`
- Result: `FM_ISOLATION_SUMMARY total=24 failed=0 concurrency=4 duration_ms=113278`

| Field | Value |
|---|---|
| `run_id` | `fm-isolation-1787273044622-10250` |
| `started_at` | `2026-08-21T00:44:04Z` |
| `finished_at` | `2026-08-21T00:45:57Z` |
| concurrency | 4 |
| candidates | 24 |
| failed | 0 |
| wall duration | 113278 ms |

## Candidate set

- `tests/fm-arm-pretool-check.test.sh`
- `tests/fm-backend-herdr.test.sh`
- `tests/fm-brief.test.sh`
- `tests/fm-captain-hold-lifecycle.test.sh`
- `tests/fm-cd-pretool-check.test.sh`
- `tests/fm-composer-ghost.test.sh`
- `tests/fm-composer-lib.test.sh`
- `tests/fm-crew-state.test.sh`
- `tests/fm-ensure-agents-md.test.sh`
- `tests/fm-grok-harness.test.sh`
- `tests/fm-herdr-lab.test.sh`
- `tests/fm-lint.test.sh`
- `tests/fm-pi-primary-types.test.sh`
- `tests/fm-pr-merge.test.sh`
- `tests/fm-review-diff.test.sh`
- `tests/fm-send-popup-settle.test.sh`
- `tests/fm-send-settle.test.sh`
- `tests/fm-send-strict.test.sh`
- `tests/fm-spawn-batch.test.sh`
- `tests/fm-supervision-instructions.test.sh`
- `tests/fm-test-run.test.sh`
- `tests/fm-tmux-submit-busy.test.sh`
- `tests/fm-transition-lib.test.sh`
- `tests/fm-x-mode.test.sh`

## Durations

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 45356 | 0 | 2 | `tests/fm-backend-herdr.test.sh` |
| 35415 | 0 | 24 | `tests/fm-x-mode.test.sh` |
| 35095 | 0 | 4 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | 0 | 1 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | 0 | 21 | `tests/fm-test-run.test.sh` |
| 17558 | 0 | 8 | `tests/fm-crew-state.test.sh` |
| 16582 | 0 | 5 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | 0 | 12 | `tests/fm-lint.test.sh` |
| 9562 | 0 | 11 | `tests/fm-herdr-lab.test.sh` |
| 6768 | 0 | 10 | `tests/fm-grok-harness.test.sh` |
| 6290 | 0 | 14 | `tests/fm-pr-merge.test.sh` |
| 5569 | 0 | 6 | `tests/fm-composer-ghost.test.sh` |
| 4563 | 0 | 16 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | 0 | 22 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | 0 | 7 | `tests/fm-composer-lib.test.sh` |
| 3025 | 0 | 18 | `tests/fm-send-strict.test.sh` |
| 2753 | 0 | 17 | `tests/fm-send-settle.test.sh` |
| 2166 | 0 | 15 | `tests/fm-review-diff.test.sh` |
| 1315 | 0 | 3 | `tests/fm-brief.test.sh` |
| 975 | 0 | 19 | `tests/fm-spawn-batch.test.sh` |
| 598 | 0 | 13 | `tests/fm-pi-primary-types.test.sh` |
| 513 | 0 | 9 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | 0 | 20 | `tests/fm-supervision-instructions.test.sh` |
| 99 | 0 | 23 | `tests/fm-transition-lib.test.sh` |

## Families refused concurrency

`bin/fm-test-isolation-proof.sh --pool <family>` runs the same concurrent proof over a whole `bin/fm-test-run.sh` family, for a stateful family that stays serial on CI but might earn bounded local concurrency.
A family is admitted only by a passing proof recorded here.

`watcher-wake-lock` was measured and **refused**.

- Date: 2026-08-28
- Command: `bin/fm-test-run.sh --family watcher-wake-lock --jobs 4`
- Result: 3 of 18 scripts failed under concurrency that pass serially.

| Script | Failure |
|---|---|
| `tests/fm-watch-checkpoint.test.sh` | `watch lock pid survived quiet checkpoint timeout` |
| `tests/fm-watch-recovery-loop.test.sh` | `handling successor did not surface the crew event within a poll interval or two (waited 4s)` |
| `tests/fm-watch-arm.test.sh` | `re-arm stayed live instead of surfacing durable wakes and the still-open remote decision` |

These are wall-clock assertions about how quickly a real watcher reaches its next poll, so CPU oversubscription breaks them without any shared-state collision.
Admitting the family would trade a duration win for a load-dependent flake, so the family stays serial and `--jobs` continues to refuse it.
Making these assertions event-driven rather than interval-bounded is the prerequisite for re-running this proof.

## Scope

Each worker used a separate mode-`0700` temporary root and private `TMPDIR` and `TMP`.
The harness cleared ambient `FM_HOME` and `FM_*_OVERRIDE` values for every worker and verified that global Git configuration was unchanged.
A candidate failure fails the aggregate run and requires investigation rather than a retry.

## Re-run

```sh
bin/fm-test-isolation-proof.sh --list
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json
bin/fm-test-run.sh --check-coverage
```

To re-test a family refused above:

```sh
bin/fm-test-isolation-proof.sh --pool watcher-wake-lock --jobs 4
```
