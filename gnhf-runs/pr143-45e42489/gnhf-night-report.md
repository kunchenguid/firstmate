# Attempt-ledger typing night report (archived run)

Run id: `pr143-45e42489`
Archived pull request: https://github.com/pedromuller-del/firstmate/pull/143
Archived merge commit: `45e42489`
Captured from preserved head: `d27efc5cd33a4570911df5ec3fa8012738324499`
Current single-slot `gnhf-score.txt` and `gnhf-night-report.md` on `main` remain the later run; this copy does not replace them.

Cursor Grok 4.6

Baseline score: 0/9 at 374043d.
Final score: 3/9.
Passing assertions: 3, 4, 5.
Draft PR: https://github.com/pedromuller-del/firstmate/pull/143
Oracle: `bash bin/fm-test-run.sh tests/fm-model-telemetry.test.sh`

Stop condition: an existing test blocks refusing `unknown` on new terminal writes.
`tests/fm-model-telemetry.test.sh` `test_terminals_and_retry_links` seals `cancelled:not-applicable:unknown` and requires that write to succeed.
The contract says new rows must not write `unknown`, and existing tests must not be rewritten.
Assertion 2 therefore cannot go green.
Assertion 1 has the same class of blocker: `failed-gate`, `cancelled-gate`, usage-source incomplete seals, and subscription-sheet failed seals omit `primaryFailureClass` and require success.
Phase B cannot start until phase A is 5/5.
No behavior outside the attempt-ledger writer and its additive tests changed.

DONE

## Oracle this iteration (before the rejected edit)

```text
FM_TEST_BEGIN 2026-08-28T07:07:36Z tests/fm-model-telemetry.test.sh family=pure-contract-unit expected_gate_skip=none
ok - model telemetry records explicit outcomes, refusal quality, evidence, and linked model/effort retries
...
ok - terminal-facts round-trips a blocked class and a green none through the sheet with typed usageSource
All model telemetry tests passed.
FM_TEST_END 2026-08-28T07:10:30Z tests/fm-model-telemetry.test.sh exit=0 duration_ms=174331 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=174389
```

25 subtests, exit 0.

## Rejected attempt (iteration 8)

Patch: `rejected/iter8-refuse-unknown-on-terminal-write.diff`
Change: quota-pattern `validate_new_terminal_failure_class` on `terminal_command`, keeping `unknown` legal on historic reads.
Score that rejected it: 3/9, oracle red.

Scratch, existing-test payload `cancelled` + `primaryFailureClass=unknown`:

```text
exit=1
error: model telemetry: new terminal primaryFailureClass must be one of none, capability, refusal, timeout, quota, tool, transport, environment, external-wait, scope-change, integrity, approval-wait, custody-wait, lease-conflict, state-divergence
```

`seal-or-incomplete` without a payload still wrote `incomplete unknown` (internal path, not `terminal_command`).
`approval-wait` still recorded.

Oracle after the patch:

```text
FM_TEST_BEGIN 2026-08-28T07:12:59Z tests/fm-model-telemetry.test.sh family=pure-contract-unit expected_gate_skip=none
error: model telemetry: new terminal primaryFailureClass must be one of none, capability, refusal, timeout, quota, tool, transport, environment, external-wait, scope-change, integrity, approval-wait, custody-wait, lease-conflict, state-divergence
not ok - cancelled terminal failed
FM_TEST_END 2026-08-28T07:13:06Z tests/fm-model-telemetry.test.sh exit=1 duration_ms=6201 gate_skip=false
FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=6254
```

Writer and test edits were reverted.
The incomplete-default seal at `incomplete_terminal` still hardcodes `unknown` because that write site has no caller-supplied class.
The class would have to come from the caller that abandoned the attempt, which is not present when a later intake supersedes a stale receipt.

## Assertions

### 1 fail

A non-green terminal-facts seal with no class is still accepted and records `unknown`.
Making that refuse breaks existing tests that omit the field (`failed-gate`, `cancelled-gate`, usage-source incomplete, subscription-sheet `sub_seal`).

Red (untouched and still true):

```text
failed facts without primaryFailureClass → exit=0 status=recorded
ledger primaryFailureClass=unknown
```

### 2 fail

The four blocked classes are writable.
`unknown` remains writable on new rows because refusing it fails `cancelled terminal failed` as shown above.

Red (untouched): `primaryFailureClass=approval-wait` → exit 1, `terminal payload violates the V1 whitelist`.
Green (iters 1, 4, 5, 7): `approval-wait`, `custody-wait`, `lease-conflict`, and `state-divergence` record and surface on `sheet --format json`.
Invented class `blocked-dialog` stays refused.

### 3 pass

Red (iter 2): intake event lacked `taskId`; sheet had no `taskId` column.
Green (iter 2):

```text
ok - intake persists the task id slug and the sheet surfaces it as a column
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=167233
```

### 4 pass

Red (iter 3): `quota.decision=unknown` was accepted; sheet had no `quotaDecision` column.
Green (iter 3):

```text
ok - new intake refuses an unknown quota decision and the sheet surfaces quotaDecision
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=165215
```

### 5 pass

Red (iter 6): facts payload with `primaryFailureClass=approval-wait` → exit 1, whitelist.
Green (iter 6):

```text
ok - terminal-facts round-trips a blocked class and a green none through the sheet with typed usageSource
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=173133
```

### 6-9 fail

Phase B not started.

## Archive note

At run time the telemetry writer diff against baseline `374043d` was four files (`bin/fm-model-telemetry.sh`, `docs/documentation-audiences.json`, `gnhf-score.txt`, `tests/fm-model-telemetry.test.sh`).
That code landed via https://github.com/pedromuller-del/firstmate/pull/143 at merge commit `45e42489`.
This archive keeps only the experiment score ledger and night report from run `pr143-45e42489`.
