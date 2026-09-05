# Firstmate test isolation proof

This record owns concurrent isolation evidence for the portable parallel candidate set and admitted runner families.
`bin/fm-test-isolation-proof.sh` is the authoritative harness and `docs/fm-test-isolation-proof.json` is the portable pool's machine-readable result.
`bin/fm-test-run.sh` owns production lane partitioning and family concurrency admission.

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

## Family concurrency proofs

`bin/fm-test-isolation-proof.sh --pool <family>` runs the same concurrent proof over a whole `bin/fm-test-run.sh` family, for a stateful family that stays serial on CI but can earn bounded local concurrency.
A family is admitted to `list_concurrent_safe_families` in `bin/fm-test-run.sh` only by a passing proof recorded here.

### watcher-wake-lock: admitted

- Date: 2026-08-28
- Command: `bin/fm-test-isolation-proof.sh --pool watcher-wake-lock --jobs 4`
- Archived harness result: two consecutive runs, 18 candidates, 0 failures.

| Run | Summary |
|---|---|
| 1 | `FM_ISOLATION_SUMMARY total=18 failed=0 concurrency=4 duration_ms=394675` |
| 2 | `FM_ISOLATION_SUMMARY total=18 failed=0 concurrency=4 duration_ms=374869` |

Those archived harness runs used alphabetical launch order and oldest-worker reclamation.
They establish the worker isolation result, but they did not reproduce the production scheduler's load profile and are not the sole basis for admission.
The current harness consumes the runner's longest-hint-first schedule and reclaims any completed worker, matching the admitted execution condition.

Admission is also supported by three independent runs of the production scheduler using `bin/fm-test-run.sh --changed --base HEAD`.
Plain `--changed` automatically selected bounded concurrency at four workers; each run used longest-first scheduling, selected 19 scripts, completed with 0 failures, and finished in 208s, 216s, and 226s.
Those runs exercised the production path that the family admission enables.

These scripts assert how quickly a real watcher reaches its next poll, so they are sensitive to CPU oversubscription rather than to shared state.
An earlier attempt on the same host measured three failures (`fm-watch-checkpoint`, `fm-watch-recovery-loop`, `fm-watch-arm`) while six unrelated busy processes were running, at roughly ten runnable processes against fourteen cores.
That is the margin this family has: four workers is proven, and the failures reappear well before the machine is merely busy.
Keep `--jobs` for this family at or below the proven bound rather than raising it to fill a larger machine.

The archived harness runs showed why ordering matters: the candidate sum was 818s and the balanced four-worker target 205s, but alphabetical order finished in 395s because the 193s `fm-watch-triage` started last and ran alone at the tail.
Both `bin/fm-test-run.sh` and the current proof harness therefore order concurrent runs longest-hint-first.

### pure-contract-unit: admitted

- Date: 2026-08-28
- Command: `bin/fm-test-isolation-proof.sh --pool pure-contract-unit --jobs 4`
- Result: two consecutive runs, 32 candidates, 0 failures.

| Run | Summary |
|---|---|
| 1 | `FM_ISOLATION_SUMMARY total=32 failed=0 concurrency=4 duration_ms=161837` |
| 2 | `FM_ISOLATION_SUMMARY total=32 failed=0 concurrency=4 duration_ms=156462` |

This family is what a change to `bin/fm-test-run.sh` itself selects, so it decides that selection's wall clock.
Before admission, 14 of its scripts fell to the serial tail and the 33-script selection measured 327.3s against a 300s budget: the concurrent group was 19 scripts totalling 273.4s while the tail alone was 215.7s, dominated by `fm-calm-pi-extension` (77.5s), `fm-vendor-auth-probe` (51.0s), and `fm-muse-harness` (39.7s).
Admitting the family moves that tail into the bounded concurrent group.
Current runner-file selection was verified on 2026-08-28 with the runner and its tests bound to each measured Bash version.
Because the runner uses `#!/usr/bin/env bash` and invokes each test with `bash` from `PATH`, the stock macOS measurement used `PATH=/bin:$PATH bin/fm-test-run.sh --changed --max-wall-ms 300000` so both resolved to `/bin/bash` 3.2.57.
Two runs selected all 33 scripts, passed the five-minute result check in 153.5s and 166.8s, and reported the same two failures as `main`: `tests/fm-muse-harness.test.sh` and `tests/fm-composer-lib.test.sh`.
With Bash 5.3.9 on `PATH`, three runs of `bin/fm-test-run.sh --changed --max-wall-ms 300000` selected the same 33 scripts, completed with 0 failures, and reported 163.8s, 172.0s, and 166.9s.
All five runs used plain `--changed` with no `--jobs` flag, exercised the production automatic scheduler, and completed under five minutes.

### pr-forge: admitted

- Date: 2026-09-03
- Command: `bin/fm-test-isolation-proof.sh --pool pr-forge --jobs 4`
- Result: two consecutive runs, 6 candidates, 0 failures.

| Run | Summary |
|---|---|
| 1 | `FM_ISOLATION_SUMMARY total=6 failed=0 concurrency=4 duration_ms=198594` |
| 2 | `FM_ISOLATION_SUMMARY total=6 failed=0 concurrency=4 duration_ms=186796` |

The production runner measured the same family at `--family pr-forge --jobs 1` in 409.2s and at `--jobs 4` in 237.9s, both with 0 failures, so four workers return 1.72x on it.
That is close to the family's ceiling rather than a scheduling loss: its longest script runs 198.5s, so no partition of these six can finish faster than about 2.1x.
The family's clock is two long scripts that do not contend: `fm-pr-check-security` (198.5s) and `fm-teardown` (194.1s) each own a worker for nearly the whole run, and `fm-pr-merge` (118.5s) plus `fm-x-mode` (79.4s) fill the other two.
`bin/fm-test-isolation-proof.sh`'s own `--list-exclusions` keeps `fm-pr-check-security` and `fm-teardown` out of the mixed PORTABLE pool, where they would share a machine with unrelated lock and forge stress.
Admitting them inside their own family is a different question and this proof answers it: the family's six scripts are safe with each other at four workers.

### secondmate: admitted

- Date: 2026-09-03
- Command: `bin/fm-test-isolation-proof.sh --pool secondmate --jobs 4`
- Result: two consecutive runs, 21 candidates, 0 failures.

| Run | Summary |
|---|---|
| 1 | `FM_ISOLATION_SUMMARY total=21 failed=0 concurrency=4 duration_ms=536586` |
| 2 | `FM_ISOLATION_SUMMARY total=21 failed=0 concurrency=4 duration_ms=571247` |

An earlier proof on 2026-09-03 refused this family on `tests/fm-backlog-handoff.test.sh`, failing two runs of three with `Task "pre-move-crash" not found in this backlog`.
The cause was in the case's crash injection, not in shared secondmate state.
Its fake `tasks-axi` killed the handoff and then slept a fixed second before delegating to the real binary, expecting to be torn down during that pause.
Nothing tore it down: the fake outlives the process it kills, so on a host slow enough for the case's next assertions to take longer than a second, the orphan woke up and completed the very move the case requires left undone, which then made the recovery step fail.
Direct observation of the source and destination backlogs during the injected crash showed exactly that, the item moving one second after the crash while the case was still asserting.

The injection is now decided by observation rather than by a clock.
`fm_fake_crash_injector` in `tests/lib.sh` drops an `fm-crash-inject <pid>` shim that signals the target and returns only once that process is observably gone, and the pre-move fake never delegates the move at all.
All four crash injections in that file use it, so none of them is a wall-clock bet any more.
Under a synthetic five-minute load average above 30, the case failed on the old injection and passed six of six on the new one, and the whole script passed end to end twice at that load.

### session-bootstrap: admitted

- Date: 2026-09-03
- Command: `bin/fm-test-isolation-proof.sh --pool session-bootstrap --jobs 4`
- Result: two consecutive runs, 11 candidates, 0 failures.

| Run | Summary |
|---|---|
| 1 | `FM_ISOLATION_SUMMARY total=11 failed=0 concurrency=4 duration_ms=337928` |
| 2 | `FM_ISOLATION_SUMMARY total=11 failed=0 concurrency=4 duration_ms=335204` |

The earlier refusal was `tests/fm-session-start.test.sh` reporting `the digest waited 9s for inactive reconciliation's 8s state read`.
That case proves the startup digest does not block on a slow current-state read, and it decided that by timing the whole digest against a fixed eight-second sleep, which a loaded host can exceed without the property being violated.
The case now holds the slow read open instead: its fake answers only once the case releases it, and the case asserts, the moment the digest returns, that the read has not finished.
A digest that waited would therefore wait indefinitely rather than for an interval a slow host can out-run, so the assertion is stronger than the elapsed-time bound it replaces and no longer reads the host's speed.
Its scan budget was also raised to the maximum, because the previous value left two seconds of margin over the fixed sleep and was measuring the host rather than the deadline that `tests/fm-inactive-reconcile.test.sh` owns.
Both proof runs above were taken while the machine carried a five-minute load average between 8 and 14, not on an idle host.

### standalone: admitted

- Date: 2026-09-03
- Command: `bin/fm-test-isolation-proof.sh --pool standalone --jobs 4`
- Result: two consecutive runs, 28 candidates, 0 failures.

| Run | Summary |
|---|---|
| 1 | `FM_ISOLATION_SUMMARY total=28 failed=0 concurrency=4 duration_ms=301792` |
| 2 | `FM_ISOLATION_SUMMARY total=28 failed=0 concurrency=4 duration_ms=250230` |

This family is the residual set that used to sit in `unclassified`, and it exists because the catch-all itself must never be admitted.
`unclassified` is the family map's `*)` arm, so admitting it would silently grant concurrency to every test added afterwards, which is exactly the population with no proof.
`standalone` enumerates its 28 members instead, and `unclassified` stays the always-serial home for anything nobody has classified yet.
`tests/fm-test-run.test.sh` covers that split behaviorally: two `standalone` members run concurrently while an unmapped basename is refused under `--jobs` and still runs serially.

One script left the residual set rather than joining it.
`tests/fm-claude-stop-autoarm-live-e2e.test.sh` gate-skips on its opt-in variable and is now `live-harness-optin`, since a candidate that gate-skips cannot prove concurrency.

One member needs a current Pi to pass at all.
`tests/fm-pi-branch-extension.test.sh` compares firstmate's supervision-branch extension against the stock renderers of the installed `@earendil-works/pi-coding-agent`, and the proof host's global install was stale at 0.81.1 while the published release was 0.84.4.
On the stale package the case fails serially as well as concurrently, so it is a prerequisite rather than a concurrency result; both runs above pinned the current package with `FM_PI_PACKAGE_DIR`, and on a host whose global install is current the plain command reproduces them.

## Production runner effect of the 2026-09-03 admissions

Each family measured with `bin/fm-test-run.sh --family <name> --jobs <n>` on the same host, back to back, every run reporting 0 failures.
Together the pairs quantify the effect when a plain `--changed` or script-list selection contains all three families: the automatic scheduler gives each admitted family its own concurrent phase and leaves unproven work in the serial tail.
Curated `--family`, `--lane`, and `--all` selections remain serial unless the caller explicitly requests an admissible `--jobs` value, as documented by `bin/fm-test-run.sh --help`.

| family | scripts | `--jobs 1` | `--jobs 4` | speedup | recovered |
|---|---:|---:|---:|---:|---:|
| `secondmate` | 21 | 1233.1s | 453.4s | 2.72x | 779.7s |
| `session-bootstrap` | 11 | 756.4s | 286.4s | 2.64x | 470.0s |
| `standalone` | 28 | 724.6s | 261.1s | 2.78x | 463.5s |
| total | 60 | 2714.1s | 1000.9s | 2.71x | 1713.2s (28.6 min) |

No test was removed, weakened, or skipped to get there.
The three families retain the same coverage guarantees; what changed is one crash injection that no longer races, one equivalent condition-based assertion that no longer reads the host's speed, and a family map that no longer files a real-Herdr regression and an opt-in live script where they cannot run.

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

To re-run a family proof:

```sh
bin/fm-test-isolation-proof.sh --pool watcher-wake-lock --jobs 4
```

Run a family proof on an otherwise idle host.
Families recorded above have failed on elapsed-time assertions rather than on shared state, and this harness deliberately never retries a failure into green, so a proof taken on a busy machine can only refuse a family it might have admitted.
When such a failure turns out to be the assertion timing itself rather than contention, fix the assertion so it decides on an observed condition instead of a wall clock, and re-run: `session-bootstrap` was admitted that way, from proofs taken on a host that was not idle.
