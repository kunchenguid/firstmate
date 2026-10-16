# Session-lock acquire-failure classification (issue #306)

This note records the evidence for the session-lock classification guarantee that `bin/fm-lock.sh` and `bin/fm-session-start.sh` now provide, and the concrete follow-up plan for the separate managed-Codex identity work tracked in issue #1933.

## Failure mode

A Codex sandbox can deny process inspection (`ps`) or hide the harness above a minimal process ancestry, so `bin/fm-lock.sh` cannot walk its own ancestry and cannot identify the current session's harness.
Before this change, `bin/fm-lock.sh` exited with the single message `cannot locate harness process in ancestry`, and `bin/fm-session-start.sh` rendered the same read-only banner for every lock failure.
An operator therefore could not tell a genuinely held lock apart from an identity failure, even when `bin/fm-lock.sh status` reported `lock: free`.

## Classification contract

`bin/fm-lock.sh` prints a stable `FM_LOCK_REASON=<reason>` line to stderr on every identity-relevant acquire failure, beside its human-readable message, and still exits 1:

- `lock-held` - another live firstmate session genuinely holds the lock.
- `ps-unavailable` - a required ancestry inspection (`comm`, `args`, or `ppid`) failed or was denied.
- `harness-detect-failed` - all required ancestry inspections succeeded but the walk found no verified harness.

The ancestry walker returns its inspection failure through the anchor result, so acquisition classifies the failed walk without a second probe.
State-directory, write, and ownership-verification failures carry no reason line and keep the generic banner.
`bin/fm-session-start.sh` branches its banner and NEXT STEP on the reason, and for `ps-unavailable` and `harness-detect-failed` explicitly says it cannot verify the session's identity and does not claim another session holds the lock.
Every acquire failure remains read-only: the session skips every mutating step regardless of reason.

`bin/fm-lock.sh status` stays honest rather than reusing the acquire verdict:

- `free` when no lock file exists.
- `held` when the recorded pid is a live verified harness.
- `unknown` when the recorded pid is a live non-harness, an unparseable value, or a pid that inspection cannot classify because `ps` cannot inspect even the live invoking shell.
- `stale` only when a working inspection itself cannot find the recorded pid.

## Reproduction

Run the focused suite, which fakes `ps` to produce each class on a temporary home:

```sh
bin/fm-test-run.sh tests/fm-lock.test.sh tests/fm-session-start.test.sh
```

The controlled shape from the issue reproduces the acquire failure under a denied `ps`; status already reported `lock: free` for that empty state before this change.
The acquisition diagnostic and session-start banner now identify the inspection failure instead of implying another holder.

## Follow-up plan: managed Codex identity (#1933)

The smallest root-cause fix for #306 is diagnostic only, and it deliberately does not add a Codex identity fallback: recognizing managed Codex Desktop requires a new identity source, an ownership sidecar, and dead-owner reclaim rules, which is far larger than this classification change and cannot be added without weakening the "never infer lock ownership from lack of evidence" invariant.
A safe #1933 implementation should be a separate change, and its concrete shape is:

1. Add a verified identity marker pair to `bin/fm-harness.sh` detection: managed Codex Desktop is recognized only from the exact `CODEX_CI=1` plus a UUID-shaped `CODEX_THREAD_ID`, never from a bare environment name or a lone marker.
2. Record the thread identity in a sidecar beside the numeric `state/.lock` pid, so ownership survives short-lived tool subprocesses that cannot see the long-lived harness process.
3. Reclaim only a recorded pid that inspection proves dead; refuse a live competing owner and refuse a different live Codex thread identity, exactly as the current lock refuses a live owner.
4. Keep the unmanaged-shell path fail-closed and unchanged, and keep process-inspection denial classified `ps-unavailable` rather than treated as identity.
5. Add harness-detection and session-lock regression coverage for the marker pair, the sidecar, dead-owner reclaim, and the live-competing and different-thread refusals.

This #1933 work is out of scope for the #306 change and must not relax lock concurrency or fake ownership when identity cannot be verified.
