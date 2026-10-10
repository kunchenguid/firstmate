# Declared mechanical verification of a ship `done:`

Audience: maintainer verification.

This record supports the declared-verification half of the ship `done:` gate owned by [`../../bin/fm-dod-lib.sh`](../../bin/fm-dod-lib.sh), whose header owns the `state/<id>.verify` format, and summarized in [`../architecture.md`](../architecture.md).
It records the empirical demonstration that one mechanical check refuses a bad `done:` and accepts a good one, because that is the only claim the pilot makes.
It records nothing about coverage the pilot does not exercise.

## What the structural gate cannot see

The named-head reachability gate proves a commit left the worker's disposable copy.
It cannot prove the change works.
A worker can push a correct-looking diff, satisfy every reachability test, and report `done:` while the URL the change claims to have fixed is dead.
An independent reviewer reading that diff sees a correct-looking diff, so review does not close this gap either; the declared check does, by fetching the URL and reporting the status it actually got.
Declared verification therefore complements independent review rather than replacing it, and upstream firstmate PR #1470 (closed stale 2026-08-25) remains the separate, reviewer-side proposal.

## The demonstration

Run 2026-09-27 on Linux 6.17.0-35-generic against upstream firstmate `3b689975`, with GNU bash 5.2.21, curl 8.19.0, and Python 3.14.7.

One task, one `done:` line, one declared check, two outcomes.
The task is put in the shape the structural gate already accepts: a real git worktree whose named head is reachable from `refs/remotes/origin/fm/declared`, `kind=ship`, `mode=no-mistakes`, and the status log's only line is `done: PR https://example.test/o/r/pull/9 checks green`.
Its declaration is a single line in `state/declared.verify` at mode 600:

```
http: http://127.0.0.1:<port>/ 200 the live fix is deployed
```

The orchestrator's own current-state read decides it.
With the local site up and serving that text, `bin/fm-crew-state.sh declared` printed:

```
state: done · source: status-log · PR https://example.test/o/r/pull/9 checks green
```

The site was then stopped and nothing else changed - same task, same commit, same `done:` line, same declaration.
The same command printed:

```
state: blocked · source: status-log · declared verification failed: http: http://127.0.0.1:43333/ could not be fetched
```

The worker that reported `done:` evaluates neither read.

## Where the ready decision enforces it

Declared verification runs at the enforcement points listed below, through the one shared refusal in `fm_dod_verify_declared_checks_pass`.
`bin/fm-pr-check.sh` runs it before its named-head skip arm on every registration, so a registration whose forge-reported head already proves reachability still refuses a failing declared check.
`bin/fm-crew-state.sh` runs it before emitting a terminal ship run-step `done` and on its status-log `done:` read, so a completed attributed run with a failing declaration reads `blocked` with the refusal reason.
The per-poll secondmate ledger publish in `bin/fm-inactive-reconcile.sh` skips declared verification and runs only the named-head gate, so a poll never waits on a network check.
The merge-time re-record (`FM_PR_CHECK_MERGE=1` in `bin/fm-pr-check.sh`) is deliberately not an enforcement point for declared verification, in any shape: it is not a ready decision.
It still runs the named-head gate exactly as before and still skips the draft refusal and the fleet-ledger write, because the invariant is measured at the ready decision rather than continuously; gating the captain's merge would turn a readiness gate into a continuous availability gate on a third party's action.
The enforcement points listed above are unchanged: registration and the crew-state current-state reads still run it.
A task that declares no verification still behaves exactly as before at every one of them.

## Refreshing this record

```
bash tests/fm-crew-state.test.sh     # test_declared_verification_decides_a_pushed_ship_done and test_terminal_run_step_done_refuses_a_failing_declaration
bash tests/fm-pr-check-security.test.sh  # test_failed_declared_verification_refuses_registration
bash tests/fm-dod-lib.test.sh        # all declared-verification cases
bash tests/fm-fleet-snapshot-view.test.sh  # the blackholing declared check reads blocked at the snapshot boundary
```

The latest refresh did not run green in the pipeline, and no environment below is claimed as a green refresh.
In no-mistakes run `01M3RKQJ6HNM413740VBE4C10M` on 2026-09-30 against upstream firstmate `eb77f02b`, with the same host and tool versions, `tests/fm-crew-state.test.sh` exited 0 with 285 ok, `tests/fm-dod-lib.test.sh` exited 0 with 31 ok, and `tests/fm-fleet-snapshot-view.test.sh` exited 0 with 19 ok.
In that same run `tests/fm-pr-check-security.test.sh` exited 1 after 14 ok at `not ok - teardown race: refused cleanup removed persisted authority`, stopping before this change's declared-verification cases, so that run did not exercise them.
Outside the gate worktree on a clean archive of base `eb77f02b`, that suite exited 0 with 45 ok, and `ok - teardown cannot race merged-poll authority consumption` ran by name and passed.
Outside the gate worktree on pushed head `fc923209`, that suite exited 0 with 47 ok, and `ok - fm-pr-check refuses registration on a failing declared verification despite a proven forge head` and `ok - FM_PR_CHECK_MERGE=1 skips declared verification in every shape while registration still refuses` passed by name.
On GitHub CI for this PR, all nine "Behavior portable serial" checks passed.
The failure reproduced only in the loaded gate worktree and did not reproduce on clean base `eb77f02b` or on GitHub CI; load is suspected but not established, because nobody instrumented the race.
It is timing-dependent by construction: `test_teardown_cannot_race_authority_consumption` (`tests/fm-pr-check-security.test.sh:3097`) starts a watcher in the background at `:3118`, spins on `sleep 0.01` at `:3122` until that watcher begins its validated poll, asserts at `:3135` that a teardown during the poll is refused, and fails at `:3137` asserting the refused cleanup left the persisted authority intact.
That test touches no code path this change modifies: it exercises the `merge-authority` transaction in `bin/fm-teardown.sh`, which this change leaves untouched, and declares no verification, while this change's only edit to that script adds `state/<id>.verify` to three cleanup `rm` lists.
`tests/fm-crew-state.test.sh` drives the demonstration above end to end through `bin/fm-crew-state.sh` over a real throwaway git repo and a real local HTTP server, with no harness and no model, and its run-step case drives a terminal attributed run whose passing declaration reads `done` and whose failing declaration reads `blocked`.
`tests/fm-pr-check-security.test.sh` covers the newly covered registration shape: a non-empty forge head whose named-head proof passes still refuses because the declared check fails, recording no `pr=` and arming no merge poll.
`tests/fm-fleet-snapshot-view.test.sh` runs a full snapshot over a declared `http:` target that accepts the connection and never answers, and asserts the task reads `blocked` with the declared-verification refusal rather than `unknown` under the snapshot's real crew-state bound.
`tests/fm-dod-lib.test.sh` covers the library directly: the live/dead pair, a reachable site serving the wrong content, the wrong status, and a response over the size cap, `run:` and `file:` in both directions, a `file:` target that exists but cannot be read, a stdin-reading `run:` that cannot consume the checks after it, the pass bound with its refusal wording distinct from an ordinary failure, a configured pass bound used unchanged at or below its maximum and refused with both numbers above it, a bound mechanism that fails before the command runs, an absent declaration gating nothing, a declaration that is not a firstmate-private file, an oversized declaration including one padded with NUL bytes, a declaration that passes the private-file check but then fails to read, and a malformed or unknown check.

## Mutation evidence

The checks are load-bearing rather than decorative: on 2026-09-27 three independent mutations of `bin/fm-dod-lib.sh` were each caught by `tests/fm-dod-lib.test.sh`.

| Mutation | Test that failed |
| --- | --- |
| The gate call removed from `fm_dod_accept_ship_done` | `a done: whose declared live check cannot reach the site was accepted (exit 0)` |
| An unknown check verb skipped instead of refused | `an unknown declared check was accepted (exit 0)` |
| The private-file validation of the declaration bypassed | `a world-readable declaration was trusted (exit 0)` |

## What the pilot does not establish

A declaration is optional, and an absent one gates nothing, so this pilot says nothing about tasks that declare no checks.
No mechanism decides which tasks should declare which checks; that is firstmate's judgment at dispatch.
The pilot exercises `http:` end to end through the orchestrator, `run:` and `file:` through the orchestrator's run-step read as well as directly at the library, over a local server only; it establishes nothing about a remote host, TLS, redirects beyond curl's own `-L`, or authenticated fetches.
A target ends at the first space, so a path or URL containing one is outside `file:` and `http:` and needs `run:`; nothing in the pilot exercises that case.
Guaranteed: a declaration that exists and fails refuses the `done:` claim at every enforcement point: `bin/fm-pr-check.sh` registration, the `bin/fm-crew-state.sh` run-step emit, and `fm_dod_accept_ship_done`'s status-log path; a declaration present but untrusted or malformed refuses the same way.
Not guaranteed: every record under `state/` is same-uid, this declaration included, so the gate detects an honest false-done and does not defeat a same-uid worker that removes or rewrites its own declaration.
A written-then-deleted declaration is indistinguishable from one that was never written.
