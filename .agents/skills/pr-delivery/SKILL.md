---
name: pr-delivery
description: >-
  Agent-only procedure for handling check: pr-delivery wakes from the bounded
  main-home PR delivery loop. Use on every check: pr-delivery wake to enumerate
  merge-eligible PRs, merge under configured authority
  via fm-pr-merge.sh, fleet-sync after merge, and follow the normal teardown path.
user-invocable: false
metadata:
  internal: true
---

# pr-delivery

`bin/fm-pr-delivery.sh` discovers open PRs for merge-capable registered projects and classifies each head with live gh evidence.
The watcher and locked session start run its bounded `scan` adjunct; when a merge-eligible PR exists, they queue `check: pr-delivery` with the scan payload.

This skill owns every handling turn for that wake.
Do not invent a parallel PR poll or merge path.

## On wake

1. Read the wake payload from the drain.
   It is `merge-eligible: ...` with `project=`, `repo=`, `pr=`, `task=`, `url=`, and `head=` fields.
2. Run `bin/fm-pr-delivery.sh show` when you need the current reason-coded blocked queue for operator context.

## merge-eligible

1. Reconcile the named task with `bin/fm-crew-state.sh` when current state matters.
2. Confirm the PR URL, task id, project, and expected head still match the payload and the blocked queue does not show a stronger hold.
3. Decide merge authority:
   - With standing or task `yolo=on`, merge when the scan classified the PR as eligible.
   - Otherwise escalate to the captain for explicit merge approval before calling `bin/fm-pr-merge.sh`.
4. Merge only through `bin/fm-pr-merge.sh <task-id> <full-pr-url> --expected-head <payload-head>`.
   If the expected-head guard refuses, leave the PR unmerged and let the delivery scan classify the new head.
   Never call `gh` or `gh-axi pr merge` directly around that helper.
5. After a successful merge, refresh the project clone through the guarded fleet-sync path (`bin/fm-fleet-sync.sh`).
6. Continue normal ship supervision: validation state, PR ready reporting, teardown only after landing is confirmed.

## Holds this scan respects

The scan already blocks on checks, mergeability, review issues, migration evidence, unresolved authority decisions, destructive or real-contact decisions, and missing task linkage.
Do not override a hold the scan reported without new evidence or captain authority.
