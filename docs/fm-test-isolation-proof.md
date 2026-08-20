# Firstmate test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/fm-test-isolation-proof.sh` is the authoritative harness and `docs/fm-test-isolation-proof.json` is the machine-readable result.
`bin/fm-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-08-20
- Command: `bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-slack-isolation-addendum.json`
- Result: `FM_ISOLATION_SUMMARY total=25 failed=0 concurrency=4 duration_ms=189201`

| Field | Value |
|---|---|
| `run_id` | `fm-isolation-1787206852635-409475` |
| `started_at` | `2026-08-20T06:20:52Z` |
| `finished_at` | `2026-08-20T06:24:01Z` |
| concurrency | 4 |
| candidates | 25 |
| failed | 0 |
| wall duration | 189201 ms |

## Candidate set

- `tests/fm-arm-pretool-check.test.sh`
- `tests/fm-backend-herdr.test.sh`
- `tests/fm-brief.test.sh`
- `tests/fm-cd-pretool-check.test.sh`
- `tests/fm-composer-ghost.test.sh`
- `tests/fm-composer-lib.test.sh`
- `tests/fm-crew-state.test.sh`
- `tests/fm-decision-hold-lifecycle.test.sh`
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
- `tests/fm-slack-captain-channel.test.sh`
- `tests/fm-spawn-batch.test.sh`
- `tests/fm-supervision-instructions.test.sh`
- `tests/fm-test-run.test.sh`
- `tests/fm-tmux-submit-busy.test.sh`
- `tests/fm-transition-lib.test.sh`
- `tests/fm-x-mode.test.sh`

## Durations

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 44699 | 0 | 14 | `tests/fm-pr-merge.test.sh` |
| 41422 | 0 | 1 | `tests/fm-arm-pretool-check.test.sh` |
| 40136 | 0 | 25 | `tests/fm-x-mode.test.sh` |
| 37725 | 0 | 8 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 32074 | 0 | 2 | `tests/fm-backend-herdr.test.sh` |
| 29662 | 0 | 22 | `tests/fm-test-run.test.sh` |
| 24513 | 0 | 19 | `tests/fm-slack-captain-channel.test.sh` |
| 23769 | 0 | 4 | `tests/fm-cd-pretool-check.test.sh` |
| 16205 | 0 | 7 | `tests/fm-crew-state.test.sh` |
| 12196 | 0 | 11 | `tests/fm-herdr-lab.test.sh` |
| 8576 | 0 | 10 | `tests/fm-grok-harness.test.sh` |
| 8386 | 0 | 20 | `tests/fm-spawn-batch.test.sh` |
| 5428 | 0 | 16 | `tests/fm-send-popup-settle.test.sh` |
| 4438 | 0 | 15 | `tests/fm-review-diff.test.sh` |
| 3409 | 0 | 17 | `tests/fm-send-settle.test.sh` |
| 3321 | 0 | 18 | `tests/fm-send-strict.test.sh` |
| 3239 | 0 | 3 | `tests/fm-brief.test.sh` |
| 2586 | 0 | 5 | `tests/fm-composer-ghost.test.sh` |
| 2086 | 0 | 23 | `tests/fm-tmux-submit-busy.test.sh` |
| 1792 | 0 | 12 | `tests/fm-lint.test.sh` |
| 442 | 0 | 21 | `tests/fm-supervision-instructions.test.sh` |
| 312 | 0 | 9 | `tests/fm-ensure-agents-md.test.sh` |
| 193 | 0 | 24 | `tests/fm-transition-lib.test.sh` |
| 103 | 0 | 6 | `tests/fm-composer-lib.test.sh` |
| 22 | 0 | 13 | `tests/fm-pi-primary-types.test.sh` |

## 2026-08-20 refresh

`tests/fm-slack-captain-channel.test.sh` joined the proven-isolated set after the previous 2026-07-29 proof, which covered only 24 candidates and so could not gate that member.
Rather than graft one measurement onto another run's artifact, the whole proof was re-run at concurrency 4 to produce a single coherent 25-candidate archive.
This run supersedes the 2026-07-29 proof (`FM_ISOLATION_SUMMARY total=24 failed=0 concurrency=4 duration_ms=149010`); every duration above comes from the one run recorded here.
The candidate set is whatever `bin/fm-test-isolation-proof.sh --list` reports and is unchanged by this refresh.

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
