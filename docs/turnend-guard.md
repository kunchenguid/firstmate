# Primary turn-end supervision guard

This is the current contract for the primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`; primary scope lives in `bin/fm-primary-scope-lib.sh`.
The related command guards have separate owners: [watcher-arm protection](arm-pretool-check.md) and [working-directory protection](cd-guard.md).

## Current invariant

When a task, process-event source, or registered custom check needs supervision, the primary must not end a turn without a current supervisor.
The turn-end guard requires an identity-matched watcher process and a fresh beacon.
The mid-turn pull guard can recognize an extension-owned watcher handoff; that does not relax the turn-end predicate.

## Guard predicates

An unmarked linked worker worktree is exempt.
`FM_HOME` selects private home state; `FM_STATE_OVERRIDE` can select an isolated state directory for tests.
The session-start wrappers use the same scope owner, as described in [native startup](sessionstart-nudge.md).

No required supervision means exit 0.
A healthy watcher means exit 0.
Otherwise the guard prints a reason-specific banner and returns 2, including a recovery instruction from `bin/fm-supervision-instructions.sh` for the detected harness.
An unreadable payload, malformed loop field, or missing `jq` fails open because the guard cannot safely establish the continuation bound.
A true `stop_hook_active` continuation marker exits 0 to prevent an infinite stop loop.

The ordinary watcher grace is 300 seconds unless `FM_GUARD_GRACE` overrides it.
A stale beacon or identity mismatch never establishes supervision. Preserved legacy mode records do not satisfy the predicate.

## Harness integration

| Harness | Integration | Continuation boundary |
| --- | --- | --- |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` calls the predicate at logical-run settlement. | One operational `turn-end-guard` follow-up, delivered with `deliverAs: "followUp"`; the extension keeps its latch across internal tool turns. |
| Codex | `.codex/hooks.json` registers the shared Stop predicate. | The native hook receives exit 2; the loop marker bounds the continuation where the host invokes this hook. |

Pi's internal follow-up remains separate from Feishu input and is never projected into the Feishu outbox.
Pi also requires `.pi/extensions/fm-primary-pi-watch.ts` for extension-owned watcher continuity.
The separate [live task continuation boundary](pi-supervision-branch.md#live-task-continuation) checks retained goals before settlement; a healthy watcher alone is not task completion.
Codex follows its bounded foreground checkpoint protocol; native hook coverage is version- and surface-dependent, with interactive startup limitations documented in [native startup](sessionstart-nudge.md).
TraeX is worker-only and has no primary integration.
No adapter manufactures supervision with a shell ampersand.

## Verification

`tests/fm-turnend-guard.test.sh` covers primary scope, watcher and daemon ownership, stale beacons, and bounded continuation.
`tests/fm-guard-stale-banner.test.sh` covers the pull guard's persistent and extension supervision models.
`tests/fm-supervision-instructions.test.sh` covers harness-specific recovery instructions.
`tests/fm-pi-watch-extension.test.sh` covers the Pi extension's supervision boundary.
[Version-scoped supervision evidence](verification/supervision.md) records empirical results separately from this current contract.
