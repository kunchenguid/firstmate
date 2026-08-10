# Firstmate ADLC

Standing delivery process model for Firstmate fleets (captain-approved 2026-08-10).

This document is the one owner of the ADLC stage map and scout-when-required rules.
Task lifecycle mechanics stay in [`AGENTS.md`](../AGENTS.md) section 7.
Supervision mechanics stay in [`AGENTS.md`](../AGENTS.md) section 8.
Hard laws stay in [`AGENTS.md`](../AGENTS.md) section 1.

## What ADLC means here

ADLC is the **agentic delivery lifecycle** for Firstmate fleets.
It serves the same goal as a traditional software delivery lifecycle: intent, build, review, land, and learn.
It shortens cycles by pairing agents for implementation and checks with human gates for authority and product judgment.
It is a process model only.
It is not a second orchestration runtime, control plane, or rename of existing roles.

## Stage table

| Stage | Human/agent | Firstmate mechanism |
| --- | --- | --- |
| Goal | Captain | Intake, backlog item, acceptance criteria |
| PRD / investigation | Scout when needed | `scout` → `data/<id>/report.md`; promote via `fm-promote` |
| Architecture | Scout when multi-subsystem/greenfield | Report + constraints in ship brief |
| Implementation | Agents | Ship crewmate, isolated worktree, `fm-spawn` |
| Human review | Captain / configured authority | `needs-decision`, ask-user, **merge authority** |
| Testing & eval | Agents + forge | `no-mistakes` when rigor selected; CI; PR-CI guardians |
| Land / deploy | Merge authority + platform | `fm-pr-merge` / local merge after approval; deploy is platform (e.g. Vercel), not a firstmate universal auto-deploy |
| Monitoring | Firstmate + optional project checks | Watcher, merge poll, guardians; prod APM only if project registers it |
| Continuous iteration | Fleet | Backlog re-eval, open-work, interrupt-resume, secondmates |

## Default path

```text
Goal
  → [scout if uncertain]
  → Ship
  → human decisions (when required)
  → automated checks
  → green PR
  → captain merge (or standing yolo for green routine merges)
  → platform deploy (project-owned)
  → supervise / loop
```

Ship is the default deliverable once implementation is authorized.
Keep bounded research inside the ship unless a scout rule below fires.

## When scout is required

These cases are binding:

- Unresolved uncertainty could change whether or what to build.
- Multi-subsystem or greenfield architecture needs a design boundary before implementation.
- The captain explicitly asks for investigation, design, or a report only.

Otherwise ship is the default.
Do not open a parallel design-only scout when established evidence already answers the question and implementation intent is clear.
A scout report may recommend implementation.
It does not authorize it.
Promote with `fm-promote` when the captain authorizes the ship.

## Delivery mode is rigor, not a different lifecycle

Delivery modes (`no-mistakes`, `direct-PR`, `local-only`) choose how hard the path validates before a PR or local branch is ready.
They are orthogonal to ADLC stages.
ADLC does not force `no-mistakes` on every ship (for example a pure process-doc or internal tooling change may use `direct-PR` when the project's standing posture and task classification allow it).
Resolve mode at intake per [`AGENTS.md`](../AGENTS.md) section 7.
Do not invent a second lifecycle per mode.

## Yolo is orthogonal

Yolo is merge and gate authority posture, not a stage.

- **Yolo off** (common standing default): the captain owns merges and captain-gated ask-user findings.
- **Yolo on**: firstmate may decide routine gates within the captain's original request and accepted task criteria, and may merge only green work.
- Never merge a red PR without a current explicit captain instruction that states that concrete merge.

Standing yolo never authorizes destructive, irreversible, or security-sensitive choices.
Those still need explicit captain word.
Details: [`AGENTS.md`](../AGENTS.md) section 7 and the `ask-user-authority` skill.

## Hard laws ADLC does not relax

ADLC does not weaken section 1 hard rules.
Full text lives in [`AGENTS.md`](../AGENTS.md) section 1.
In short:

- No firstmate project writes (crews change product code).
- No merge without captain word (except standing yolo for green routine merges).
- No discard of unlanded work without explicit authority.
- Crews never address the captain.

## Done means landed

A ship is done when the change is on the default branch (or an approved local-only merge completed).
A worker `done: PR <url>` line means the PR is ready for configured merge authority.
It is not land.
Teardown follows confirmed land, not the worker's PR-open or checks-green signal alone.
See [`AGENTS.md`](../AGENTS.md) section 7 for teardown and merge owners.

## Non-goals

ADLC does not add:

- A second control plane, workflow engine, or parallel task state machine.
- Universal auto-deploy or auto-prod patch without captain and platform ownership.
- Marketing renames of crewmates, scouts, or secondmates.
- A restatement of full section 7 or section 8 contracts (point there instead).

## Where this applies

Apply ADLC at intake when classifying ship vs scout, when deciding whether scout is required, and when explaining outcomes to the captain in plain language.
Keep operator-facing wording on project outcomes (investigation, fix, PR, merge, blocker), not internal stage marketing labels.
Cross-reference this doc; do not copy the stage table into `AGENTS.md` or briefs.
