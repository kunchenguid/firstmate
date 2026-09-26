---
name: gnhf
description: >-
  Agent-only procedure for wiring the installed gnhf orchestrator (ralph/autoresearch-style
  bounded coding loop) into a firstmate ship task.
  Use when the captain asks for an overnight, unattended, or "keep going until X" autonomous
  loop on a project, names gnhf explicitly, or asks to check on or steer a running gnhf loop.
  Owns how firstmate stays out of the loop itself, what the crewmate's brief must require,
  agent-flag mapping to the crewmate's own harness, Companion vs Hands-Off mapping to firstmate
  steering, sparse status reporting, the morning-review checklist, and safety rules.
user-invocable: false
metadata:
  internal: true
---

# gnhf

`gnhf` (npm package `gnhf`, installed at `$(npm root -g)/gnhf`) is an agent orchestrator: it
repeatedly calls a coding agent against one objective, committing each successful small change
and rolling back failures, until a stop condition or a runtime cap.
Its own agent-facing contract lives at `$(npm root -g)/gnhf/skills/gnhf/SKILL.md`, and its CLI
shape is authoritative from `gnhf --help`; read both before writing the brief below, and read
them again if this file and the installed package appear to disagree - the installed package
wins.

## Firstmate never runs gnhf itself

Hard rule 1 still applies: firstmate does not touch project state.
`gnhf` runs only inside a crewmate's own isolated task worktree, driven by that crewmate, never
by firstmate in a conversational turn.
File the request as an ordinary ship task per AGENTS.md section 7 (resolve delivery mode and
`yolo` posture at intake exactly as any other ship task) and write a brief per section 11 that
tells the crewmate to invoke `gnhf` itself, on its own branch, as part of doing the work.
The result reaches `main` through that task's ordinary selected delivery path (no-mistakes,
direct-PR, or local-only) - gnhf is a tool the crewmate uses mid-task, not a second delivery
mechanism.

## What the brief must require

- Run `gnhf` with `--current-branch` so every accepted iteration commits land directly on the
  task's own `fm/<task-id>` branch, never on a separate `gnhf/...` branch the delivery path
  would not see.
- Never pass `--push`. The task's selected delivery mode owns every push; gnhf pushing on its
  own would race or duplicate that path.
- Never run `gnhf` outside the crewmate's assigned isolated worktree.
- Pass `--agent <agent>` matching the harness this crewmate was itself spawned with, so the loop
  reasons with the same model/tooling the captain already chose for this task.
  Cross-reference the crewmate's harness against gnhf's supported `--agent` roster
  (`gnhf --help`) before assuming a match; a harness gnhf does not support (or does not support
  under the same name) is a blocker to report, not a substitution to make silently.
- A concrete, observable objective and explicit non-goals (`--stop-when` and the prompt body,
  per the package skill's prompt skeleton).
- Verification the objective must satisfy: the project's own test and lint gate, run after each
  meaningful slice, not a new bespoke check invented for the loop.
- Mandatory runtime caps: `--max-iterations` and/or `--max-tokens` sized to the captain's ask
  (an unbounded overnight run is never authorized).
- A stop condition gnhf can observe directly (test suite green, a named script's exit code),
  never a subjective one like "looks good".

## Hands-Off vs Companion

- **Hands-Off**: the crewmate launches one bounded `gnhf` run per the brief above, waits for it
  to exit, then reports the final result per the task's normal done/failed reporting. No
  intervention needed unless one of the package skill's own early-intervention triggers fires
  (hard failure, runaway scope, destructive behavior, impossible prerequisite).
- **Companion**: firstmate steers the crewmate between rounds through the ordinary steering
  inbox (AGENTS.md section 7, `fm-send`), the same as any other live task - there is no separate
  gnhf-specific channel. Between rounds, apply the package skill's Companion Review procedure
  (inspect diff/commits, run independent verification, decide mergeable / needs follow-up / do
  not merge) before authorizing the next bounded `gnhf` invocation or accepting the result as
  done.

## Status reporting

Per the brief's ordinary sparse status contract: `working:` when the loop starts, one line per
cap or stop-condition exit (which one, and the observed outcome), and `failed:`/`blocked:` on a
real failure - never a line per iteration. The loop's own commit history is the source of truth
for what happened each round; the status file only needs the phase changes a supervisor would
act on.

## Morning review

When the captain returns asking how an overnight run went, do not answer from memory or relay
the worker's self-report verbatim.
Reconcile against the task's actual current state (`bin/fm-crew-state.sh`, the branch's commit
log, and the task's status file) before reporting mode, branch, changes, verification result,
stop-condition outcome, and recommended next action - the same reconstruction the package
skill's own Morning Review section describes, run against firstmate's own state rather than a
fresh `git log`/`pgrep` guess.
The captain's own screenshot-verification rule for UI work still applies before anything is
reported "done"; a passing gnhf stop condition is not a substitute for it.

## Safety

- Never on a project the captain has paused.
- Never in the primary checkout - only inside the crewmate's assigned isolated worktree.
- No `--push`; the delivery path owns every push.
- Runtime caps (`--max-iterations` / `--max-tokens`) are mandatory, not optional, for an
  unattended run.
- Destructive git cleanup of a gnhf branch is never authorized; unlanded work rules (AGENTS.md
  hard rule 3) apply exactly as they would to any other in-progress branch.
