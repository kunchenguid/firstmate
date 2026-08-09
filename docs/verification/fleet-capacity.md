# Fleet capacity verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the shared fleet-capacity projection (`fm-fleet-capacity.v1`) and its shadow-stage guarantees.
Current facts and dated recorded evidence: the integration base, shared projection, sentinel wiring, private sentinel removal, and capacity latency.

## Integration base

The reviewed reconciliation base is commit `454b10d` (`reconcile(fleet): merge origin/main onto the fleet-refill integration base`), created on 2026-08-08.
It merges local `main` tip `d40fd7f` and `origin/main` tip `833a9a2`, whose common ancestor is `2cf0283b`.
Both histories are preserved: local `main` owns `bin/fm-fleet-refill.sh` and the accepted fleet lifecycle design, while upstream owns its own five commits, and the twelve duplicated PRs resolve as identical content with the refill script preserved from the local side.

The integration branch passed the canonical review pass before any runtime work.
Review verdict: panel `7d94ba3c...` with routes `minimax.minimax-m3` and `qwen.qwen3.7-max`, verdict `2xPASS`, closure-satisfied, on 2026-08-08.

Ancestry proofs, run from the branch under verification:

```sh
git log --format='%H %P' -1 454b10d
git merge-base d40fd7f 833a9a2
git merge-base --is-ancestor d40fd7f 454b10d && echo 'local main contained'
git merge-base --is-ancestor 833a9a2 454b10d && echo 'origin main contained'
```

Verified:

```text
454b10d7fe3233c256047f16be1658dd3ac762d6 d40fd7f6b74c064744b903601b2fce3e1ba730e1 833a9a25bcf2ae522d6f93dbbd9911a6d8e7c409
2cf0283b811e81a821cddf5b7f74e1f7de8e2881
local main contained
origin main contained
```

## Historical cron sentinel quarantine

The fleet-depth cron sentinel was quarantined to alert-only on 2026-08-08 at commit `9e7247b` while the shared projection remained in shadow.
That dated transition established that legacy capacity arithmetic was not authoritative and could not stage dispatch.
The later removal evidence is recorded under `## Private sentinel removal`; the tracked runtime now uses the shared projection and refill sentinel rather than the quarantine implementation.

## Latency (shadow)

Measured on 2026-08-08 against integration base `454b10d`.

`/usr/bin/time` (GNU time) is not installed on this host, so the measurement used the bash `time` keyword with `TIMEFORMAT='count-json wall=%R s'`, which emits the same output shape:

```sh
TIMEFORMAT='count-json wall=%R s'
time bin/fm-fleet-refill.sh --count-json >/dev/null
```

Exact output, worktree empty-fleet baseline:

```text
count-json wall=0.068 s
```

Real-fleet-size read-only measurement, projecting the real home's state without modifying it:

```sh
TIMEFORMAT='count-json wall=%R s'
time FM_STATE_OVERRIDE=/home/holu/fmate/firstmate/state bin/fm-fleet-refill.sh --count-json >/dev/null
```

Exact output:

```text
count-json wall=7.898 s
```

The projection only reads the real home's state: git status remained clean, `state/attempts` gained no files, and the 16 meta records were unchanged before and after.
The real-fleet run exceeds the 2000 ms expectation with the default per-read timeout (2 s) at the current fleet size, so the Task 13 cutover gate owns the accepted latency posture (parallel reads and the total deadline are configurable before consumers switch).

## Live parity

Task 13 cutover proof, measured 2026-08-08 on branch `fm/fm-fleet-refill-implementation-r1` (HEAD `3eac13a`), integration base `454b10d`.
One frozen observation drives `--count-json`, the snapshot embed, and the sentinel; rows and aggregates compare byte-identically (the `generated` timestamp is the only field that may differ).

Worktree, empty fleet:

```sh
cd /home/holu/.treehouse/firstmate-b8697d/1/firstmate
frozen=/tmp/fm-capacity-frozen.json
bin/fm-fleet-refill.sh --count-json > "$frozen"
FM_CAPACITY_OBSERVATION_FILE="$frozen" bin/fm-fleet-snapshot.sh --json | jq '.capacity' > /tmp/fm-capacity-snap.json
diff <(jq -S '.rows,.aggregate' "$frozen") <(jq -S '.rows,.aggregate' /tmp/fm-capacity-snap.json) && echo "LIVE-PARITY-OK"
```

Exact output:

```text
LIVE-PARITY-OK
```

Real-fleet read-only measurement (the projection only READS `/home/holu/fmate/firstmate/state`):

```sh
frozen=/tmp/fm-capacity-frozen-real.json
FM_STATE_OVERRIDE=/home/holu/fmate/firstmate/state bin/fm-fleet-refill.sh --count-json > "$frozen"
FM_CAPACITY_OBSERVATION_FILE="$frozen" bin/fm-fleet-snapshot.sh --json | jq '.capacity' > /tmp/fm-capacity-snap-real.json
diff <(jq -S '.rows,.aggregate' "$frozen") <(jq -S '.rows,.aggregate' /tmp/fm-capacity-snap-real.json) && echo "REAL-LIVE-PARITY-OK"
```

Exact output: `REAL-LIVE-PARITY-OK`.
The frozen real-fleet object held 10 rows with aggregate `productive_count=0 reserved_ownership_count=10 ambiguous_count=10 observation_complete=false alert_only=true reconciliation_required=true refill_safe=false`.
`git -C /home/holu/fmate/firstmate status --short` printed nothing before and after, and `state/attempts` gained no files (0 before, 0 after).

## Latency (final)

Measured 2026-08-08 against integration base `454b10d`, branch HEAD `3eac13a` (sequential), then corrected by the captain-approved bounded-parallel default at branch HEAD `f5c7`-era (see the correction below).
`/usr/bin/time` (GNU time) is not installed on this host, so the measurement used the bash `time` keyword with `TIMEFORMAT='count-json wall=%R s'`, the same output shape as Task 3.

Worktree empty-fleet baseline:

```sh
TIMEFORMAT='count-json wall=%R s'
time bin/fm-fleet-refill.sh --count-json >/dev/null
```

Exact output:

```text
count-json wall=0.067 s
```

Real-fleet-size read-only measurement (`FM_STATE_OVERRIDE=/home/holu/fmate/firstmate/state`; 15 meta records, 10 projected rows), sequential:

```text
count-json wall=3.284 s
```

## Bounded-parallel latency correction (captain-approved)

The sequential real-fleet run exceeded the 2000 ms budget (dead legacy endpoints eat the per-read timeout), so per the captain's decision the latency follow-up used bounded PARALLEL reads rather than shortening the per-endpoint timeout: the per-row timeout semantics for slow-but-live workers are unchanged (`FM_CAPACITY_READ_TIMEOUT_SECS=2`), rows are still sorted deterministically by attempt/task identity, and the whole collection still runs under `FM_CAPACITY_TOTAL_TIMEOUT_SECS`. `FM_CAPACITY_PARALLEL` defaults to 4 (the smallest measured value clearing the budget).

Measured 2026-08-08 (read-only, real home), sequential vs parallel:

```text
FM_CAPACITY_PARALLEL=1  count-json wall=3.248 s
FM_CAPACITY_PARALLEL=2  count-json wall=2.168 s
FM_CAPACITY_PARALLEL=4  count-json wall=1.495 s
FM_CAPACITY_PARALLEL=8  count-json wall=0.984 s
```

At the new default (4), the real-home wall time is consistently under the budget:

```text
run1 wall=0.832 s
run2 wall=0.853 s
run3 wall=0.755 s
```

Regression coverage shipped with the default: `test_parallel_reads_are_byte_identical` pins that the default (>1) produces byte-identical output to a forced-sequential projection of the same state; the existing `test_total_deadline_marks_unfinished_rows_ambiguous` pins that the total deadline still holds under the parallel default; `test_disappearing_record_is_ambiguous` forces sequential collection because its torn-read hook is serial-path-only. A data-shape bug found during the real-home read (the ambiguous-row `attempt_id` was the string `"null"` instead of JSON `null`) was fixed with a regression assertion.

Automatic refill stays disabled until this evidence passes; `config/refill-auto` is not created.

## Acceptance

Task 13 safety-gate evidence, 2026-08-08, integration base `454b10d`, branch HEAD `fb230a0` with the fixture reconciliation `9cb53bb`.
Commands run:

```sh
bash tests/fm-fleet-refill.test.sh
bash tests/fm-capacity.test.sh
bash tests/fm-refill-admission.test.sh
bash tests/fm-refill-sentinel.test.sh
bash tests/fm-fleet-snapshot-view.test.sh
bin/fm-lint.sh bin/fm-fleet-refill.sh bin/fm-fleet-snapshot.sh bin/fm-refill-sentinel.sh tests/fm-capacity.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-refill-sentinel.test.sh
bin/fm-doc-audience-check.sh
```

Results:

- `tests/fm-capacity.test.sh`: 14 ok, all passed, including the two new composition fixtures (`composition fixtures prove byte-equivalent rows and aggregates across consumers`, `timing-dependent fields never break deterministic parity`).
- `tests/fm-refill-admission.test.sh`: 6 ok, all passed.
- `tests/fm-refill-sentinel.test.sh`: 3 ok, all passed (safe sentinel silent, alert sentinel notifies, never recounts).
- `tests/fm-fleet-snapshot-view.test.sh`: 16 ok, all passed, including the new byte-parity embed test (`snapshot capacity embed is byte-identical to the frozen observation`).
- `tests/fm-fleet-refill.test.sh`: 22 ok, all passed, after `9cb53bb` adapted the three quarantine-era fixtures to the cut-over verdict (`test_cutover_verdict_derives_from_shared_projection`, `test_cutover_ignores_legacy_manifest_and_output_mtimes`, `test_cutover_still_propagates_serialization_debt`, `test_cutover_verdict_is_unchanged_in_shadow_mode`): they now assert the shared-projection-derived summary (`productive=`/`refill_safe=` present) and keep the stronger negatives (`DISPATCH-NEEDED`, `active=`, `battery=` absent). The pre-adaptation `not ok` recorded below is resolved by that commit; the safety gate is fully green.
- `bin/fm-lint.sh` on the changed files: clean (ShellCheck 0.11.0 pinned), exit 0; `bash -n` clean on all three changed scripts.
- `bin/fm-doc-audience-check.sh`: `fm-doc-audience-check: ok surfaces=67 local_links=214`, exit 0.

Automatic refill stays disabled because nothing in the tracked side creates `config/refill-auto`; enablement remains a separate home-local operator decision.

## Private sentinel removal

Recorded evidence from 2026-08-08 shows that `/home/holu/fmate/firstmate/data/fleet-depth-check.sh` is absent and `crontab -l | grep -c "fleet-depth-check"` returned `0`.
The exact recorded command output remains under `### Step 5 verification, exact outputs` below.
No wrapper replaced the private script, and historical `state/fleet-manifest.jsonl` remains inert rather than becoming an input to the shared classifier.
These are dated private-home facts, not verification newly performed in this worktree.

## Refill sentinel cadence

Task 14 (Decision OS 7.6 leaf) defines the cadence schema for the shared fleet sentinel (`bin/fm-refill-sentinel.sh`).

Schema: `config/refill-sentinel` is a gitignored home-local file (one per home; the primary home's is not inherited into secondmate homes). Its first non-comment, non-empty line is a positive integer giving the sentinel cadence in seconds. Comments start with `#`. Example content:

```sh
600
```

Resolution precedence in `bin/fm-refill-sentinel.sh` (one resolver, `fm_refill_sentinel_cadence`):

1. `FM_REFILL_SENTINEL_CADENCE_SECS` (env) when set and a positive integer.
2. `$FM_CONFIG_OVERRIDE/refill-sentinel` (fallback `$FM_HOME/config/refill-sentinel`) when present and its first non-comment, non-empty line is a positive integer.
3. `600` (the default) when the file is absent, comment-only, or invalid.

The sentinel reports the ACTIVE cadence so the wiring is verifiable: every log line under `FM_REFILL_SENTINEL_LOG` (default `state/refill-sentinel.log`) carries `cadence=<seconds>`, and the `FM_REFILL_SENTINEL_VERBOSE=1` consumed-aggregate note prints `cadence=<seconds>` too. The sentinel never schedules itself: it is invoked by its callers at that cadence (the away-mode daemon heartbeat fleet review and the attended refill path), and it owns only cadence resolution, the candidate query, logging, and notification policy.

Verify the wiring (frozen observation, temp config):

```sh
tmp=$(mktemp -d); mkdir -p "$tmp/config"; printf '120\n' > "$tmp/config/refill-sentinel"
FM_CONFIG_OVERRIDE="$tmp/config" FM_CAPACITY_OBSERVATION_FILE=<frozen-capacity.json> \
  FM_REFILL_SENTINEL_VERBOSE=1 bin/fm-refill-sentinel.sh 2>&1 | grep 'cadence=120'
```

Tracked wiring is implemented in the existing `bin/fm-supervise-daemon.sh` housekeeping pass.
A sibling housekeeping step gates `state/.subsuper-last-refill-sentinel` on the cadence reported by `bin/fm-refill-sentinel.sh --cadence`, propagates the effective home/state/config context, and routes `REFILL-ALERT:` output through the daemon's existing escalation buffer.
A missing or failing sentinel remains unavailable-safe and does not transfer or discard daemon ownership.
No scheduler, daemon, or supervision framework was added.

Idempotent obligation retry keeps pending effects inside the single attempt record (`state/attempts/<id>.json`, receipt `state:"pending"`), never in a separate obligation file.
Claim retry remains in the existing spawn/refill replay owners.
Successful PR-poll and local-only completion invoke the exact attempt terminal transaction, while the existing watcher heartbeat and locked startup reconciliation passes retry surfaced current attempt IDs.
Missing or nonzero terminal execution preserves ownership and surfaces a warning.
All replays remain idempotent against the write-once receipt set; no new loop is built.

Deferred private operation after the tracked change is merged: create the real home's optional cadence file if the operator wants an explicit value.

```sh
printf '600\n' > /home/holu/fmate/firstmate/config/refill-sentinel
```

The tracked heartbeat wiring does not create this file automatically and uses the documented 600-second default while it is absent.
This deferred private file creation is distinct from the tracked wiring already implemented.

## Task 14 acceptance

Task 14 safety-gate evidence, 2026-08-08, integration base `454b10d`, branch `fm/fm-fleet-refill-implementation-r1` (parent commit `b50fdce`).
Commands run:

```sh
bash tests/fm-session-start.test.sh
bash tests/fm-watch-triage.test.sh
bash tests/fm-fleet-snapshot-view.test.sh
bash tests/fm-refill-sentinel.test.sh
bash tests/fm-capacity.test.sh
bash tests/fm-attempt.test.sh
bin/fm-lint.sh bin/fm-session-start.sh bin/fm-watch.sh bin/fm-fleet-snapshot.sh bin/fm-refill-sentinel.sh tests/fm-session-start.test.sh tests/fm-watch-triage.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-refill-sentinel.test.sh
bin/fm-doc-audience-check.sh
```

Results:

- `tests/fm-session-start.test.sh`: 44 ok, all passed, including the new fleet-state attempt line (`fleet-state digest exposes the attempt id, generation, obligations, reconciliation, and exit hint`).
- `tests/fm-watch-triage.test.sh`: 47 ok, all passed, including the new bounded heartbeat surface (`heartbeat backstop surfaces a reconciliation-required attempt once, then stays bounded`).
- `tests/fm-fleet-snapshot-view.test.sh`: 17 ok, all passed, including the new per-task attempt exposure (`tasks[] expose attempt id, generation, obligations, and reconciliation; absent attempts are null`).
- `tests/fm-refill-sentinel.test.sh`: 6 ok, all passed, including the three cadence-config tests (config honored, invalid/comment-only falls back to 600, env still overrides).
- `tests/fm-capacity.test.sh`: 14 ok, all passed.
- `tests/fm-attempt.test.sh`: 11 ok, all passed.
- `bin/fm-lint.sh` on the changed files: clean (ShellCheck 0.11.0 pinned), exit 0; `bash -n` clean on all four changed scripts.
- `bin/fm-doc-audience-check.sh`: clean, exit 0.

Automatic refill stays disabled because nothing in the tracked side creates `config/refill-auto`.
The optional real-home cadence file remains a deferred post-merge operator action, while tracked housekeeping wiring already uses the default when the file is absent.

## Decision OS contract

Audience: maintainer verification. Version-scoped evidence for the attended Decision OS main-steward adapter (`bin/fm-br-receipt.sh`, Task 5 of the fleet-refill implementation) and its live contract guard (`tests/live-decision-os-contract.test.sh`).

Pinned installed contracts, verified on 2026-08-08 against the real registered clone `/home/holu/decision-os` and the installed CLIs:

- `br --version` = `0.2.19`.
- `br comments add <ID> -m <MESSAGE>` (alias `--content`); `br comments list <ID> --json` returns a JSON array whose items carry `.text`; there is NO `br comments show` (`br comments show` exits 2 with the parent help).
- `br show --json <id>` returns a JSON ARRAY (one element per issue), never an object; the adapter's jq requires an array and fails closed on any other shape (`br show --json ""` returns an INVALID_ID error object, which is not an array).
- `br ready --json` returns an array when run from inside a clone (`.beads/*.db` discovery is cwd-based) and a NOT_INITIALIZED error object otherwise.
- `br close`, `br update --status`, and `br ready --help`/`br show --help` accept `--no-auto-flush`; br reads default to auto-flushing the tracked `.beads/issues.jsonl` export, so read-only br invocations in the guard pass `--no-auto-flush` and never write the tracked JSONL.
- `scripts/br_worktree_storage.py` subcommands and shapes: `verify-session --repo <path> [--agent <name>]` (prints `verify-session: OK (storage=...)`; best-effort `[session]` repair writes nothing when no bead id resolves from the checkout), `preflight --repo <path> --status-out <path> --br-bin <path>` (writes only to the isolated evidence copy under the status-out parent and fails if source store hashes change), `claim <issue_id> --repo <path> --agent <name> --br-bin <path>`. `PYTHONPATH=src .venv/bin/python` is the installed invocation.

Live guard run, once with the env gate on, 2026-08-08:

```sh
cd /home/holu/.treehouse/firstmate-b8697d/1/firstmate
FM_LIVE_DECISION_OS=1 bash tests/live-decision-os-contract.test.sh
```

Exact output (exit 0):

```text
ok - verify-session --repo --agent works
ok - br show --json returns an array
ok - br comments list exists and comments show does not
ok - preflight requires and accepts --repo --status-out --br-bin
```

Run again without the env gate it self-skips: `skip: FM_LIVE_DECISION_OS not set (live Decision OS contract guard)`, exit 0.

No failure was observed. Note: the registered clone is a live store with active tracker-writing lanes; a dirty `.beads/issues.jsonl` working tree observed during the run is live lane traffic (an unrelated no-mistakes lane was actively writing `.beads` at the time), not output of the guard, and was left untouched.

## Review-repair evidence

On 2026-08-08, focused public-interface runs passed for `fm-attempt-migrate`, `fm-br-receipt`, `fm-capacity`, `fm-cleanup`, `fm-disposition`, `fm-refill-admission`, `fm-refill-sentinel`, `fm-spawn-worktree-settle`, `fm-terminal`, `fm-watch-triage`, and `fm-session-start`. Bash syntax checks passed for every touched executable and test. The exercised behavior includes separate claim/closure receipts, tracker crash replay, launch evidence, exact Git/forge and local-only disposition, per-effect cleanup recovery and provider return, bounded structured admission, post-retirement refill, sentinel housekeeping cadence, and startup/heartbeat reconciliation. The dedicated downstream lint and full-suite gates remain authoritative.

The private fleet-depth removal evidence below remains the dated operational record: `data/fleet-depth-check.sh` was absent and crontab inspection returned zero matching entries. Tracked heartbeat/sentinel and terminal-recovery wiring is implemented. The home-local `config/refill-sentinel` cadence file remains intentionally deferred until after merge, and `config/refill-auto` remains absent.

## Final acceptance

Task 15 acceptance evidence, 2026-08-08, integration base `454b10d`, branch `fm/fm-fleet-refill-implementation-r1` (parent commit `d769ccc`).

### Deletion and alert-only rollback

The legacy arithmetic (`TASKS_DIR`, `MANIFEST`, `ACTIVE_WINDOW_MIN`, `QUEUE_WINDOW_MIN`, `MIN_BATTERY`, `MIN_OPEN`, the output-mtime loop, and the legacy `active=`/`battery=` verdict line) was already removed by the Task 3 quarantine and the Task 13 cutover. Task 15 verified zero residual references in `bin/` and updated every remaining prose reference to the new contract. The serialization-debt probe and the authoritative bead-query diagnostic remain; `state/fleet-manifest.jsonl` is left untouched and simply stops being read (verified: no runtime script reads it).

The rollback flip: when `config/refill-auto` is absent and `FM_REFILL_AUTO` is not `1`, `--refill` prints the admission verdict and `fleet-ok: alert-only` and exits 0 without winning the home lock, re-reading beads, creating claims, printing dispatch commands, or launching. Every attempt, bead, branch, ref, copy, and receipt is preserved (byte-compare pinned by `test_rollback_is_alert_only_and_preserves_everything`), and re-enabling the gate resumes from the persisted effect receipts through the same idempotent claim-replay, obligation-retry, and terminal-reconciliation paths. The projection still reports ambiguity and reconciliation exactly as before; missing evidence never becomes zero capacity (`test_rollback_never_restores_legacy_arithmetic`). The sentinel reports `mode=alert-only` unless the gate is on.

### Commands

```sh
bash tests/fm-fleet-refill.test.sh
bash tests/fm-refill-admission.test.sh
bash tests/fm-refill-sentinel.test.sh
bash tests/fm-capacity.test.sh
bash tests/fm-attempt.test.sh
bash tests/fm-fleet-snapshot-view.test.sh
bin/fm-lint.sh bin/fm-fleet-refill.sh bin/fm-refill-sentinel.sh tests/fm-fleet-refill.test.sh tests/fm-refill-admission.test.sh tests/fm-refill-sentinel.test.sh
bin/fm-doc-audience-check.sh
# full suite: bin/fm-test-run.sh over 143 of 145 scripts (the two known-hanging
# scripts fm-on and fm-remote-secondmate-lifecycle-e2e bounded by `timeout 120`)
```

### Results

- `tests/fm-fleet-refill.test.sh`: 25 ok, all passed (22 prior + 3 new: legacy-manifest/output-mtime no-fallback, rollback alert-only + state preservation, missing evidence never becomes zero capacity).
- `tests/fm-refill-admission.test.sh`: 6 ok, all passed; the Task 12 attended command-printing test was reconciled to the rollback contract (`test_rollback_mode_is_alert_only_and_never_dispatches`).
- `tests/fm-refill-sentinel.test.sh`: 7 ok, all passed (6 prior + the new alert-only/automatic mode-report test).
- `tests/fm-capacity.test.sh`, `tests/fm-attempt.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`: all passed.
- Full suite: `FM_TEST_SUMMARY total=143 failed=6 skipped_gate=17 duration_ms=2639024`. The two known-hanging scripts were bounded: `fm-on bounded rc=124` and `fm-remote-secondmate-lifecycle-e2e bounded rc=124` (both hang in this shell environment on the remote-job stdin machinery, as documented).
- `bin/fm-lint.sh` (changed files and the repo): clean (ShellCheck 0.11.0 pinned), exit 0; `bash -n` clean on both changed scripts.
- `bin/fm-doc-audience-check.sh`: `fm-doc-audience-check: ok surfaces=67 local_links=214`, exit 0.

### Full-suite failures, exact, with the environment set named

Environment set (pre-existing, unchanged from the Task 0 baseline, not fixed by Task 15):

- `tests/fm-teardown.test.sh`: exactly one `not ok` - `leaked-process-reap: leaked worktree process survived teardown` (`lsof` is not installed).
- `tests/fm-calm-pi-extension.test.sh`: fails on the installed Pi v22.23.1 (`TypeError: this.getMarkdownTransformers is not a function` in interactive-mode.js).
- `tests/fm-backend-herdr-focus-flash-e2e.test.sh`: `not ok - the Part C doomed pane never acquired a stable persistent sleep child process` (real herdr runtime).
- `tests/fm-on.test.sh` and `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`: hang (bounded at 120 s each, both rc=124), remote-job stdin machinery.
- `tests/fm-remote-job.test.sh`: fails in-suite (`not ok - remote job worker did not report ready after startup`; interference pattern), passes in isolation (`ALL TESTS PASSED`, rc=0). `tests/fm-remote-job-orphan-reap.test.sh` passed in-suite (exit=0).

Newly surfaced by this first full-suite run in this environment (root-caused, both environment/latent-branch issues, outside Task 15's write set):

- `tests/fm-test-run.test.sh`: `comm: file 2 is not in sorted order` under the ambient `en_US.UTF-8` locale; passes with `LC_ALL=C` (rc=0). The runner's coverage-guard `comm` steps assume the C collation CI uses.
- `tests/fm-gotmp.test.sh`: `not ok - teardown exited non-zero with a valid tasktmp`; root cause is that `bin/fm-teardown.sh` sources `fm-disposition-lib.sh` and `fm-cleanup-lib.sh` (Tasks 4 and 8/9) but the test's `make_fake_root` symlink list predates those dependencies (`fm-teardown.sh: No such file or directory` for fm-disposition-lib.sh). A latent fixture lag introduced by Task 9's cleanup extraction, not by Task 15.

All six failures are therefore the documented pre-existing environment set plus two root-caused environment/latent-branch issues; every refill, capacity, attempt, terminal, snapshot, and admission test is green.

### Step 5 verification, exact outputs

Forbidden-symbol check (scoped to runtime code; the deliberate negative fixture in `tests/fm-fleet-refill.test.sh` is excluded by scope):

```text
$ grep -rn "ACTIVE_WINDOW_MIN\|QUEUE_WINDOW_MIN\|MIN_BATTERY\|MIN_OPEN\|fleet-manifest" bin/ && echo "LEGACY-ARITHMETIC-FOUND" || echo "NO-LEGACY-ARITHMETIC"
NO-LEGACY-ARITHMETIC

$ grep -c "productive_count\|reserved_ownership_count" bin/fm-fleet-refill.sh bin/fm-fleet-snapshot.sh bin/fm-refill-sentinel.sh | grep -v ":0" | grep -v fm-capacity-lib.sh || echo "CONSUMERS-ONLY"
bin/fm-fleet-refill.sh:5
bin/fm-refill-sentinel.sh:4
```

The two count hits are consumer jq reads of `.aggregate.productive_count`/`.aggregate.reserved_ownership_count` (refill's admission summary and sentinel's consume-only note); `bin/fm-fleet-snapshot.sh` embeds the object whole (0 lines, filtered by `grep -v ":0"`). The counters appear only in the one classifier (`bin/fm-capacity-lib.sh`, excluded) and its consumers.

File-map verification at the current branch head `d670a84`: `git diff --name-only main...HEAD` = 83 paths (80 at the `d769ccc`-era map recorded below, plus the three later non-map paths added by the pipeline review and test-fix commits, listed below). Every plan map path the implementation needed is in the branch diff. Three map paths were never touched and are documented map over-predictions: the plan document itself (already on `main` at `d40fd7f`), `tests/fm-backlog-handoff.test.sh` (no task modified it; Task 14 exposure/recovery coverage landed in the mapped `tests/fm-session-start.test.sh`/`tests/fm-watch-triage.test.sh`), and `tests/fm-teardown-endpoint-safety.test.sh` (no task modified it; extraction-identity coverage landed in the mapped `tests/fm-teardown.test.sh`). Non-map diff paths, documented deviations: 34 files are exactly the Task 0 reconciliation set (origin/main's five upstream commits `833a9a2`, `be32879`, `167ff42`, `60eb534`, `06b33aa` brought in by the `454b10d` merge), `tests/live-decision-os-contract.test.sh` is the Task 5 live-contract guard added by `4b7ef96` beyond the map's `tests/fm-br-receipt.test.sh` entry, and three further paths were added by the later pipeline commits: `bin/fm-supervise-daemon.sh` (review `4f6e780` reworked the Task 14 daemon heartbeat surface), `tests/fm-gotmp.test.sh` (test-fix `be7e025`), and `tests/fm-calm-pi-extension.test.sh` (test-fix `ebcf659`). The two-dot branch diff from the base commit `833a9a2` is 62 paths; its 16 non-map paths are the plan/design and local-main files reconciled onto the base (`docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md`, `docs/architecture.md`, `docs/configuration.md`, `docs/scripts.md`, `AGENTS.md`, `bin/fm-decision-os-review-migrate.sh`, `bin/fm-serialization-debt.sh`, `bin/fm-test-run.sh`, `.gitignore`, `.pi/extensions/fm-calm.ts`, `tests/fm-decision-os-review-migrate.test.sh`, `tests/fm-spawn-decision-os-reviews.test.sh`), the Task 5 live guard, and the same three later-review/test-fix paths.

Home-aware scans (read-only; nothing under `/home/holu/fmate/firstmate` was modified) and crontab inspection, exact outputs:

```text
$ rg -uu -l "fleet-manifest" /home/holu/fmate/firstmate/ | grep -v '\.git/' | grep -v 'docs/superpowers/plans/'
/home/holu/fmate/firstmate/config/crew-dispatch.json
/home/holu/fmate/firstmate/data/fm-fleet-refill-design-fresh-eyes-r1/report.md
/home/holu/fmate/firstmate/data/fm-fleet-refill-design-fresh-eyes-r1/brief.md
/home/holu/fmate/firstmate/bin/fm-fleet-refill.sh
/home/holu/fmate/firstmate/data/fm-fleet-refill-plan-review-r1/report.md
/home/holu/fmate/firstmate/data/learnings.md
/home/holu/fmate/firstmate/data/dos-fleet-reality-audit-r1/report.md
/home/holu/fmate/firstmate/data/dos-fleet-gate-inventory/report.md
/home/holu/fmate/firstmate/data/fm-fleet-depth-counter-investigation-r1/report.md
/home/holu/fmate/firstmate/data/fm-fleet-depth-counter-investigation-r1/brief.md
/home/holu/fmate/firstmate/state/.hb-surfaced-fm-fleet-refill-implementation-r1
/home/holu/fmate/firstmate/state/fm-fleet-refill-implementation-r1.status
MANIFEST-CONSUMER-FOUND

$ rg -uu -l "pi-subagents-1000" /home/holu/fmate/firstmate/ | grep -v '\.git/' | grep -v 'docs/superpowers/plans/'
/home/holu/fmate/firstmate/bin/fm-fleet-refill.sh
/home/holu/fmate/firstmate/data/fm-fleet-refill-design-fresh-eyes-r1/report.md
/home/holu/fmate/firstmate/data/dos-fleet-reality-audit-r1/report.md
/home/holu/fmate/firstmate/data/fm-fleet-depth-counter-investigation-r1/report.md
/home/holu/fmate/firstmate/data/fm-fleet-depth-counter-investigation-r1/brief.md
OUTPUT-PATH-REFERENCE-FOUND

$ rg -uu -l "fleet-depth-check" /home/holu/fmate/firstmate/ /home/holu/.treehouse/firstmate-b8697d/1/firstmate/
docs/verification/fleet-capacity.md            (this doc, removal record)
docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md  (both homes, plan prose)
... plus real-home data/*/report.md, brief.md and state/*.status, .hb-surfaced-* records (prose)
SENTINEL-REFERENCE-FOUND

$ crontab -l | grep -c "fleet-depth-check" && echo "CRON-SENTINEL-STILL-ACTIVE" || echo "CRON-SENTINEL-GONE"
0
CRON-SENTINEL-GONE

$ crontab -l | grep "firstmate/data/" && echo "OTHER-CRON-FIRSTMATE-ENTRIES" || echo "NO-OTHER-CRON"
15 */2 * * * /home/holu/fmate/firstmate/data/openmodel-price-check.sh >> /home/holu/fmate/firstmate/data/openmodel-price-check.log 2>&1
OTHER-CRON-FIRSTMATE-ENTRIES
```

Interpretation: the raw `rg -uu` hits are either (a) prose and volatile records (the plan/verification docs, scout reports and briefs, `config/crew-dispatch.json`'s note, and this task's own `state/*.status`/`.hb-surfaced-*` records) that document the legacy paths but never read them, or (b) the real home's pre-delivery copy of `bin/fm-fleet-refill.sh` on local `main` `d40fd7f` (the legacy released script; it is dormant - nothing invokes it: no crontab entry, no daemon, no session-start hook, no live process, and the real home's `AGENTS.md` no longer references `fm-fleet-refill`; only `bin/fm-test-run.sh`'s family map mentions the name). The tracked-side replacement reaches the real home only through the post-Task-15 no-mistakes delivery fast-forward, which is outside this task's scope (no push, no merge). No ACTIVE consumer of the legacy manifest, output paths, or private cron sentinel remains; the private cron sentinel removal (`data/fleet-depth-check.sh` absent, crontab 0 matches) is verified done by firstmate and confirmed here. The only `firstmate/data/` crontab entry is the named-safe `openmodel-price-check.sh`.

### Design-requirement re-check and the 16-task count

Every accepted design requirement maps to landed tasks (architecture section "Durable implementation capacity and attempt lifecycle design" plus the F1-F8 correction list): one attended dispatch/refill invocation (Tasks 6, 12); automatic terminal reconciliation and refill (11, 12, 13); no new scheduler/daemon/dashboard/wrapper/parser/phase machine/duplicate counter (2, 8, 9, 15 negative assertions); one shared capacity classifier (2) with consumers cut over (13); one structured cleanup operation (8, 9); write-once receipt-derived attempt model (1, F1); one outer non-reentrant terminal transaction with lock-held primitives (1, 9, 11, F2); real-history reconciliation and shadow-only consumers until post-parity cutover (0, 3, 13, F3); structured crew-state plus an enforceable total deadline and latency (2, F4); installed br/storage contracts and a pathspec transaction (5, 6, F5); centralized live disposition with fresh per-effect authority (4, 11, F6); attempt-bound copy/landing/planned-path semantics with a pre-land actual-diff recheck (1, 7, 10, 11, 12, F7); deterministic parity commands, brief wiring, exhaustive file map, split Tasks 5/8 (3, 5, 6, 8, 9, 13, 15, F8); full branch and isolated-copy lifecycle (5, 6, 7, 9, 10, 11, 12); obsolete manifests/output paths/duplicated counters/legacy compatibility reads deleted only after measured parity, never discarding unknown or unlanded work (4, 9, 11, 13, 14, 15); private cron sentinel quarantined in Task 3, removed after the Task 13 cutover proof, verified gone here (3, 13, 15); representative latency, fixture parity, crash/replay, concurrency, migration, rollback-to-alert-only, and exact verification commands (2, 3, 5, 7, 9, 10, 11, 12, 13, 14, 15).

Sixteen tasks (Task 0 through Task 15), each on a green baseline with a small commit, verified on the branch: Task 0 `454b10d` (integration base merge + canonical review), Task 1 `384e68d`, Task 2 `7b0a995`, Task 3 `9e7247b`+`58cffcb`, Task 4 `ec3e2d2`+`022fdb3`, Task 5 `4b7ef96`, Task 6 `13e8a02`, Task 7 `f3d11dc`, Task 8 `feb4fb2`, Task 9 `35871d0`+`73c131d`, Task 10 `6c63f30`, Task 11 `01a9ab3`+`74a6cec`, Task 12 `3eac13a`, Task 13 `fb230a0`+`9cb53bb`+`45d0560`+`b50fdce`, Task 14 `e5cff35`+`d769ccc`, Task 15 this commit.

Automatic refill stays disabled: nothing in this repo creates `config/refill-auto`, and `--refill` is alert-only until the gate is enabled.

### Current-head record (post-acceptance pipeline commits)

The final acceptance evidence above was recorded at the Task 15 head `f2383b8`.
The pipeline then applied the captain-approved review corrections, test fixes, and the documentation pass on this delivery branch; the current head is `d670a84`.

- `4f6e780` no-mistakes(review) "Fix durable fleet lifecycle recovery and admission": reworked `bin/fm-attempt-migrate.sh`, `bin/fm-br-receipt.sh`, `bin/fm-capacity-lib.sh`, `bin/fm-cleanup-lib.sh`, `bin/fm-disposition-lib.sh`, `bin/fm-fleet-refill.sh`, `bin/fm-merge-local.sh`, `bin/fm-pr-lib.sh`, `bin/fm-pr-poll.sh`, `bin/fm-refill-sentinel.sh`, `bin/fm-session-start.sh`, `bin/fm-spawn.sh`, and added the non-map path `bin/fm-supervise-daemon.sh`.
- `f8f4d80` no-mistakes(review) "Normalize local-only repository identity": `bin/fm-disposition-lib.sh` and `tests/fm-disposition.test.sh` (canonical repository identity for observed paths and frozen remote URLs, with remote-backed regression coverage).
- `8bd867a` no-mistakes(review) "Recover terminal replay and launch receipts": `bin/fm-spawn.sh`, `bin/fm-terminal.sh`, `tests/fm-spawn-worktree-settle.test.sh`, `tests/fm-terminal.test.sh` (duplicate-guard launch-receipt recovery and terminal replay).
- `5f0e69f` no-mistakes(review) "Fix refill exit, alert-only tolerance, teardown quiet bypass": `bin/fm-cleanup-lib.sh`, `bin/fm-fleet-refill.sh`, `bin/fm-teardown.sh`, `bin/fm-terminal.sh`, and their tests.
- `be7e025` fix(tests) "locale-neutral coverage comms and gotmp fixture lib siblings": `bin/fm-test-run.sh` and the non-map path `tests/fm-gotmp.test.sh` (resolves the Task 15-recorded gotmp fixture-lag failure; the suite now exits 0).
- `ebcf659` no-mistakes(test) "Auto-fixed orca claim and calm stub tests pass; Pi E2E flake pre-existing": `tests/fm-backend-orca.test.sh` (now exits 0) and the non-map path `tests/fm-calm-pi-extension.test.sh`.
- `d670a84` no-mistakes(document): `docs/scripts.md` inventory rows for the new fleet scripts and `docs/architecture.md` design-framing updates (both already tracked paths).

Re-verified at `d670a84`: every plan-mapped task suite exits 0 (`fm-attempt`, `fm-crew-state`, `fm-capacity`, `fm-disposition`, `fm-attempt-migrate`, `fm-br-receipt`, `fm-brief`, `fm-cleanup`, `fm-pr-check-security`, `fm-pr-merge`, `fm-terminal`, `fm-refill-admission`, `fm-fleet-refill`, `fm-refill-sentinel`, `fm-fleet-snapshot-view`, `fm-session-start`, `fm-watch-triage`, `fm-gotmp`, `fm-secondmate-safety`, `fm-backend-orca`, `fm-spawn-worktree-settle`); `tests/fm-teardown.test.sh` keeps its one recorded pre-existing `leaked-process-reap` failure (`lsof` not installed); `tests/fm-calm-pi-extension.test.sh` still fails one Pi E2E case (`Pi follow-up loaded_on case rendered a duplicate captain answer`) on the installed Pi v22.23.1, a pre-existing flake distinct from the `getMarkdownTransformers` TypeError the `ebcf659` stub resolved; `tests/live-decision-os-contract.test.sh` self-skips without `FM_LIVE_DECISION_OS`; `bin/fm-doc-audience-check.sh` reports `ok surfaces=67 local_links=214`.

Plan tracking: the 95 execution checkboxes in `docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md` were ticked against this record on 2026-08-09 (task-to-commit mapping above, per-task test and lint results in this record).
Two interpretation notes: Task 13 Step 6's private `config/refill-auto` activation stays deferred until the PR is approved and merged per the delivery instruction, and Task 13 Step 7's private cron sentinel removal rests on the recorded read-only home inspection under `## Private sentinel removal`.

Current-head lint state: `bin/fm-lint.sh` with no arguments (changed-file set against the base `833a9a2`, ShellCheck 0.11.0 pinned) exits 1 at `d670a84` with eight findings in seven locations: `bin/fm-br-receipt.sh` (SC1010 line 129, SC2015 line 217), `bin/fm-fleet-refill.sh` (SC2329 line 78, `fm_refill_paths_overlap` unused after the review rework), `bin/fm-capacity-lib.sh` (SC1007 line 226), `bin/fm-session-start.sh` (SC1007 line 738), `bin/fm-watch.sh` (SC1007 line 689), and `tests/fm-capacity.test.sh` (SC2016 line 195).
The same command was clean at the Task 15 head `f2383b8` and the full canonical set was clean at the base `833a9a2`; all eight findings were introduced by the review commit `4f6e780`.
The dedicated downstream lint gate must resolve these before final acceptance; this record does not claim lint-clean at the current head.
