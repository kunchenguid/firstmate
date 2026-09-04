---
name: subagent-review-workflow
description: >-
  Compact procedure for staged coding workflows using subagents (@explore, @plan, @oracle, @fixer).
  Use when coordinating non-trivial coding tasks that require structured exploration, planning, pre-implementation review, sole-editor implementation, and post-implementation review.
user-invocable: false
metadata:
  internal: true
---

# subagent-review-workflow

This skill owns the staged coding workflow for subagent-assisted implementation tasks.
It enforces role isolation, strict artifact handoffs, pre- and post-implementation review gates with revision loops, and sole-editor authority.

## Role verification and dynamic mapping

Before dispatching subagents, verify available agent definitions in `.pi/agents/*.md`, `~/.pi/agent/agents/*.md`, or the active harness tool definitions.
Do not assume fixed role identifiers; dynamically map requested roles to verified local agent definitions.

- `@explore` -> `Explore` or `explorer`: Read-only codebase investigator.
  Searches codebase facts, traces execution paths, and gathers technical evidence.
  Performs no file edits or test executions.
- `@plan` -> `Plan`: Read-only implementation planner.
  Designs minimal architecture, file modifications, and verification strategies based on exploration findings.
  Performs no file edits or test executions.
- `@oracle` -> `oracle` or `lelouch`: Read-only pre- and post-implementation reviewer.
  Audits exploration and plan artifacts before editing starts, and audits complete diffs against test evidence after editing completes.
  Performs no file edits or test executions.
- `@fixer` -> `@fixer` or `fixer`: Sole editor and test runner.
  Applies code modifications, executes test suites, and fixes verification failures.
  Holds exclusive authority to mutate workspace files and run verification commands.

Dynamic mapping alters role selection only and never weakens the sole-editor rule.

## Role availability and error fallback protocol

Before starting Stage 1, test subagent invocation availability in the current environment.
If any requested subagent role is undefined, unavailable, or subagent dispatch is blocked by security seatbelts:

- Do not attempt partial subagent delegation.
- Fall back immediately to the self-executed multi-pass protocol.
- Perform separate, dedicated passes in exact sequence: read-only exploration pass -> read-only planning pass -> read-only pre-implementation review pass -> fixer editing and test pass -> read-only post-implementation review pass.
- Enforce strict separation of duties during self-execution by keeping all read-only passes completely free of file edits.

## Staged execution procedure and explicit gated handoffs

```
[Stage 1: Explore & Plan]
   │
   ▼ (Exploration Findings & Plan Artifact)
[Stage 2: Pre-Implementation Oracle Review Gate]
   │
   ├── (Findings / Risks Raised) ──► [Revision Loop: Update Plan / Re-explore]
   │                                           │
   ▼ (Approved Plan)                           │
[Stage 3: Assumption Filtering & Handoff] ◄────┘
   │
   ▼ (Sanitized Handoff Packet)
[Stage 4: Implementation & Verification (@fixer)]
   │
   ▼ (Git Diff & Test Evidence)
[Stage 5: Post-Implementation Oracle Review Gate]
   │
   ├── (Findings / Defects Raised) ──► [Revision Loop: Fix & Rerun Tests (@fixer)]
   │                                             │
   ▼ (Approved Diff & Passing Evidence)          │
[Stage 6: Gate Clearance & Commit/PR] ◄──────────┘
```

### Stage 1: Exploration and planning

- Launch `@explore` to investigate codebase facts, existing patterns, and dependency structures.
- Where safe, run independent read-only investigation queries concurrently.
- Produce the Exploration Findings artifact (`EXPLORE_FINDINGS`).
- Pass `EXPLORE_FINDINGS` to `@plan` to construct the Plan Proposal artifact (`PLAN_PROPOSAL`).

### Stage 2: Pre-implementation review and revision loop

- Pass `EXPLORE_FINDINGS` and `PLAN_PROPOSAL` to `@oracle` for pre-implementation review.
- `@oracle` audits the proposal for architectural risks, edge-case gaps, and unnecessary complexity.
- Pre-Implementation Revision Loop: If `@oracle` identifies findings or risks, return to `@plan` (or `@explore` if facts are missing) to revise `PLAN_PROPOSAL`.
- Re-submit updated artifacts to `@oracle` until `@oracle` explicitly approves the plan.

### Stage 3: Handoff and assumption filtering

- Synthesize `EXPLORE_FINDINGS`, approved `PLAN_PROPOSAL`, and `@oracle` review notes into a Fixer Handoff Packet (`HANDOFF_PACKET`).
- Audit `HANDOFF_PACKET` to strip unverified assumptions, speculative guesses, and obsolete code references.
- Require every instruction in `HANDOFF_PACKET` to be grounded in verified exploration facts or explicit captain intent.

### Stage 4: Implementation and verification

- Pass sanitized `HANDOFF_PACKET` exclusively to `@fixer`.
- `@fixer` applies file modifications in controlled batches and runs verification tests.
- No other subagent or pass may edit workspace files or execute state-changing commands.
- Produce the Git Diff (`git diff`) and Test Execution Evidence (`TEST_EVIDENCE`).

### Stage 5: Post-implementation review and revision loop

- Provide `@oracle` with the complete Git Diff (`git diff`) and full `TEST_EVIDENCE`.
- `@oracle` audits the diff for plan adherence, regression risks, and code quality.
- Post-Implementation Revision Loop: If `@oracle` raises review findings, return to `@fixer` to apply corrections and rerun affected verification checks.
- Submit updated Git Diff and `TEST_EVIDENCE` to `@oracle` for re-review until `@oracle` approves.

### Stage 6: Gate clearance and delivery

- Confirm that both `@oracle` gates (pre-implementation plan approval and post-implementation diff/test approval) are passed.
- Confirm all verification checks pass cleanly.
- Proceed to commit or PR preparation under project delivery rules.

## Firstmate integration boundaries

- This workflow operates inside an isolated task worktree and does not replace `fm-spawn.sh` or worktree verification.
- Use it for Firstmate work only when the captain explicitly requests this staged workflow, and never layer its review or verification stages onto a no-mistakes delivery path.
- Captain merge authority, `yolo` posture rules, `ask-user` escalation boundaries, and no-mistakes delivery paths remain fully in force.
