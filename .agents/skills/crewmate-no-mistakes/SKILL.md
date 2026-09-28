---
name: crewmate-no-mistakes
description: >-
  Agent-only delivery procedure for a Firstmate crewmate running or recovering an ordinary no-mistakes validation.
  Use only after an implementation checkpoint is committed, when resuming an active no-mistakes run, handling one of its gates, or diagnosing a pipeline failure.
user-invocable: false
metadata:
  internal: true
---

# Crewmate no-mistakes delivery

Load this skill only after the implementation checkpoint is committed and Firstmate has instructed the task to begin ordinary no-mistakes validation, when resuming an already active run, when handling one of its gates, or before reporting a pipeline failure.
The current task brief remains the owner of task intent, delivery mode, paths, acceptance evidence, and any task-specific BITS/PPE boundary.

## Intent boundary

Pass `--intent` as only the current brief's `## Captain intent authorized for --intent` body plus later words the captain actually supplied.
Preserve those words without adding speaker labels or direct address.
Never include `## Firstmate spec`, Firstmate-authored constraints, or the worker's decisions and tradeoffs.
For a legacy brief without that section, use only words on lines marked `[captain] ` and remove that metadata prefix; if no provenance-marked captain words exist, stop and ask Firstmate.
The string must be self-sufficient: when those words refer to a report, decision, or PR, include the referenced substance in the captain's terms rather than only its pointer.

## Driving the run

Drive no-mistakes by responding to its gates, never by hand-editing findings while a run is active.
The installed no-mistakes skill, `no-mistakes axi run --help`, and each response's `help` field own the current mechanics.
Never pass `--yes` or `-y` to `no-mistakes axi run` or `no-mistakes axi respond`.

One drive call may outlive a harness command limit because the daemon accepts the response before performing the round.
Run that drive call in the background and inspect the existing run with `no-mistakes axi status`; a killed, timed-out, or slow drive call is not evidence that the daemon stopped.
Do not start a second run or repeatedly poll an unchanged run.

Never stop, restart, or update the shared no-mistakes daemon.
Before reporting a pipeline blocker, run `no-mistakes daemon status` and `no-mistakes axi status`.
Only a refused or missing daemon socket, or a run record failed with a daemon error, is a daemon blocker; otherwise reattach to a run that is still running or fixing.

## Ask-user findings

Ask-user findings belong to Firstmate, never the implementation worker.
At one ask-user gate, write only the findings verbatim and unparaphrased - id, severity, file, line, description, and authority - to the current task's `data/<task-id>/nm-<run>-findings.txt`.
Then append exactly one status event in this shape:

`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=<absolute-snapshot-path>`

Name every finding id from that gate and do not restate or summarize a finding in the status line.
Stop until Firstmate records the decision, then pass that answer through `no-mistakes axi respond`; do not implement it by hand.

## Completion

The ordinary path is complete only when no-mistakes returns at its CI-ready point with the recorded PR checks green.
Append `done: PR <full-url> checks green` and stop without merging.
Do not keep a completed worker attached merely to monitor an already green PR.

For a deployable ByteDance BITS/PPE task, do not use this ordinary path until Firstmate has applied `bits-development` and the task brief's exact-candidate PPE test gate is satisfied.
That path limits final no-mistakes to review, tests, documentation, and lint; BITS owns push, MR, and CI, and any code-changing validation fix returns through the existing BITS task and PPE before another final pass.
