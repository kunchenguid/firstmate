# Manual QA matrix: base `1bb72cc5` -> target `466e0d6`

Static QA only. No tests, linters, validation commands, or live Discord/backend calls were run.

## surfaceEvidence

| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
|---|---|---|---|---|---|
| SQ-DISCORD-ARM-01 | C-DISCORD-POLL-REACHABILITY | Watcher custom-check dispatch | Read `bin/fm-bootstrap.sh:1114-1175`, then `bin/fm-watch.sh:2372-2413`, then `bin/fm-check-lib.sh:17-52` | FAIL — token-enabled bootstrap creates `state/discord-watch.check.sh`, but the watcher special-cases only `x-watch.check.sh`; Discord falls into `fm_custom_check_snapshot_prepare`, which requires the absent `state/discord-watch.check-trust`. The poll never runs and the inbox/wake/reply flow is unreachable. Severity: blocker. Auto-fix. | A1 |
| SQ-DISCORD-CURSOR-01 | C-DISCORD-CURSOR-COMPLETENESS | Discord REST polling/cursor | Read `bin/fm-discord-poll.js:87-97,181-183` | FAIL — one request retrieves at most 100 messages after the cursor, then advances the cursor to the newest returned message. Input: cursor `1`, 101 new messages, and a bot mention at message `2`; the API page can omit `2`, while the cursor advances to `102`, permanently skipping the mention. With no cursor, the initial `limit=10` page has the same loss for an 11-message backlog. Severity: high. Auto-fix. | A1 |
| SQ-DISCORD-REPLY-01 | C-DISCORD-REPLY-RETRY-SAFETY | Direct Discord reply POST/progress | Read `bin/fm-discord-reply.js:105-153` | FAIL — progress is written only after Discord accepts a chunk and its response is parsed. Input: chunk 0 receives HTTP 200, then the process exits before line 152 (or `res.json()` fails); retry sees no progress file and posts chunk 0 again. The user receives a duplicate reply. Severity: high. Auto-fix. | A1 |
| SQ-REAPER-OWNERSHIP-01 | C-REAPER-ENDPOINT-OWNERSHIP | Inactive terminal reaper/backend dispatch | Read `bin/fm-inactive-reconcile.sh:480-504`, `bin/fm-backend.sh:407-552`, `bin/backends/zellij.sh:590-622`, and history `git show 44dcde0 e10c85c 466e0d6 -- bin/fm-inactive-reconcile.sh` | PASS — terminal cleanup validates the exact task/backend endpoint before mutation; Zellij receives the validated tab ID plus `fm-<task>` label, and tmux filters panes by exact task label before group termination and exact `=session:=window` cleanup. | A1 |

## adversarialCases

| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
|---|---|---|---|---|---|
| AC-DISCORD-TRUST-DISPATCH-01 | C-DISCORD-POLL-REACHABILITY | generated-check dispatch mismatch | A configured Discord token must cause the trusted poll script to execute on the watcher’s check cadence. | FAIL — generated Discord check has no trust registration and is rejected as an unauthenticated custom check. Blocker; auto-fix. | A1 |
| AC-DISCORD-BACKLOG-OVER-100-01 | C-DISCORD-CURSOR-COMPLETENESS | backlog larger than one REST page | Every message after the saved cursor must eventually be examined exactly once or retained for a later page. | FAIL — omitted messages are skipped permanently when the cursor is advanced to the page newest ID. High; auto-fix. | A1 |
| AC-DISCORD-POST-ACK-CRASH-01 | C-DISCORD-REPLY-RETRY-SAFETY | acknowledged POST followed by local crash | A retry must resume after the accepted chunk, not duplicate it. | FAIL — the durable marker is created after the POST, leaving an unavoidable accepted-POST/local-marker crash window. High; auto-fix. | A1 |
| AC-REAPER-TASK-ID-COLLISION-01 | C-REAPER-ENDPOINT-OWNERSHIP | endpoint label/tab collision or stale metadata | Cleanup must refuse an endpoint that cannot be proven to belong to the terminal task, preserving durable state. | PASS — validation rejects mismatched/ambiguous ownership before backend mutation; Zellij’s kill path also refuses a label mismatch. | A1 |

## artifactRefs

| id | kind | description | path |
|---|---|---|---|
| A1 | static-trace | Read-only source/history trace supporting all scenarios above; no runtime evidence claimed. | `.omo/evidence/pre-push-gate-review-manual-qa.md` |

