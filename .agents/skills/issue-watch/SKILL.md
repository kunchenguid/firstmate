---
name: issue-watch
description: >-
  Load when arming a per-node watch on one GitHub issue for swarm work (fm-issue-watch.sh), when a `check: issue-watch` wake arrives, when assigning fleet nodes to issues in a swarm-runbook charter, or when asked to monitor an issue continuously.
---

# issue-watch

Per-node watch on ONE GitHub issue: the swarm-runbook pattern where each fleet
node works an assigned issue independently and must react to new activity on
it. The watch is zero-token; only substantive changes wake firstmate, which
then decides and steers the assigned worker.

## Arming

```sh
bin/fm-issue-watch.sh arm <repo> <issue-number> <worker-target>
```

- `<worker-target>` is the exact task id or label of the worker assigned to
  the issue (fm-send.sh resolves it). The watch never sends; it records the
  target so firstmate's wake-time decision has it.
- `arm` writes `state/issue-watch.check.sh` (byte-static shim), binds it with
  `bin/fm-check-register.sh`, and records the assignment in
  `state/issue-watch.conf`. Runs on the watcher's `FM_CHECK_INTERVAL` cadence.
- Assignment ownership comes from the swarm-runbook charter's **node matrix**
  — arm only issues whose matrix row names YOUR node. Each node's FM_HOME
  keeps its own config, so cross-node double-arming is a charter violation,
  not a script error.

## What wakes and what does not

News = comments from logins other than the node's own gh login (extend the
ignore list with `ISSUE_WATCH_IGNORE_LOGINS`), a changed issue body, or an
open/closed state change. Never news: label churn, the node's own comments,
comments already reported, the backlog present at arm time (the first poll is
a silent baseline — the worker reads the issue at dispatch, the watch only
guards activity after it).

Each handled wake is an LLM turn; the baseline + own-login + id-cursor
dedup is the debounce. A poll failure or timeout always prints (fail-closed);
silence is only a proven no-op.

## Handling a `check: issue-watch` wake

1. Read the wake line: `issue-watch <repo>#<num> (worker <target>): <news>`.
2. Read the issue itself (`gh issue view <num> -R <repo> --comments`) — the
   line only earned the wake; the issue is the truth.
3. Decide per the swarm-runbook: usually one `bin/fm-send.sh <target>`
   steering message pointing the worker at the new comment; a disagreement or
   scope question goes to the workstream issue, not straight into the worker.
4. Honor the gates: a HOLD on the workstream pauses this node's worker —
   acknowledge and wait, do not grind. Captain-gated actions (rotations,
   merges, reclassification) stop with a concrete question instead.
5. Do not echo the raw wake into the task's status history; steering messages
   quote the substantive part.

## Multi-issue and multi-node notes

- One watch per home (`state/issue-watch.conf` is a single assignment). A
  node working two issues runs two firstmate homes or the fleet revisits the
  design — do not hand-roll a second conf file.
- The charter's node matrix is the ownership registry. `bin/fm-lease-lib.sh`
  is available if a workstream needs stricter claim semantics than matrix
  rows.
- Long-running: the watch survives restarts (state-backed); the worker does
  not — re-dispatch per firstmate's normal task lifecycle.

## Relationship to swarm-runbook

`swarm-runbook` owns the coordination contract (classes, charter, node
matrix, attestation format, risk tiers, closure). This skill owns only the
mechanical per-node watch. When a watch catches a newly discovered problem,
classify it per the runbook taxonomy in the same turn.

## Reference

- `bin/fm-issue-watch.sh --help` — exact modes and environment knobs
  (`ISSUE_WATCH_MAX_LINES`, `ISSUE_WATCH_BUDGET`, `ISSUE_WATCH_IGNORE_LOGINS`).
- The custom-check trust contract lives in `bin/fm-check-register.sh` and
  `docs/configuration.md`; disarm with the script, never a hand `rm` of the
  trust record.
