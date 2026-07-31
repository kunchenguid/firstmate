---
name: no-mistakes-readiness
description: >-
  Agent-only readiness and visibility procedure for no-mistakes delivery.
  Load before starting, recovering, or supervising a no-mistakes ship, and before acting on a readiness result or attach-monitor lifecycle result.
user-invocable: false
metadata:
  internal: true
---

# No-mistakes readiness and visibility

This skill is the authoritative owner of Firstmate's implementation-readiness contract and its no-mistakes visibility procedure.
The installed no-mistakes skill and live AXI help remain authoritative for pipeline phases, gates, branch custody, fixes, push, PR, and CI mechanics.
`bin/fm-no-mistakes-ready.sh --help` owns the readiness-record format and the exact monitor commands and mutation mechanics.

## Boundary

No-mistakes is the final delivery review and shipping gate.
It is not the place to finish the feature.
The implementation worker owns implementation, self-audit, project-native analysis, tests, and applicable design and runtime grounding before any pipeline run starts.
Firstmate semantically reviews that readiness evidence before no-mistakes without taking over implementation or adding a separate code-review gate.
Readiness evidence answers whether implementation is complete enough to enter the selected delivery review; it does not replace that review.

Use the same implementation worker for readiness and for driving the eventual AXI run.
Firstmate never becomes a second AXI driver and never answers a crew-owned gate directly.

## Evidence record

After the implementation is committed, have the worker initialize the task-private readiness record through the helper.
The worker replaces every pending row with a verdict and concise concrete evidence, then asks the helper to check it.
Evidence must name the command, artifact, result, or trace that supports the verdict.
A bare assertion such as "done", "looks good", or "not applicable" is not evidence.

Apply each axis to the project and accepted intent instead of imposing a fixed tool list:

- `intent_trace` maps every accepted behavior and constraint to implementation plus test, runtime, design, or documentation evidence.
- `self_audit` records the worker's inspection of the complete implementation diff for omissions, accidental scope, and contradictions with accepted intent.
- `project_analysis` records the relevant project-native analyzer, type checker, generator validation, or equivalent, or explains concretely why none can inform this change.
- `spec_kit` is `pass` whenever the project carries applicable Spec Kit material.
  Its evidence must show that applicable checklists are complete, clarifications are resolved, the plan and implementation tasks have converged on the accepted intent, analysis is current, and completed tasks reconcile with the actual work.
  Spec Kit can be `not-applicable` only when the project has no applicable Spec Kit surface.
- `focused_tests` records passing tests closest to the changed behavior.
- `full_checks` records the relevant broader suite, build, lint, or CI-equivalent checks chosen from the project's own contract.
  Do not run an irrelevant universal tool merely to fill this row.
- `implementation_complete` confirms that no known accepted behavior, edge case, follow-up fix, placeholder, or intentionally deferred implementation remains.
- `decisions` is `clear` only when no unresolved product, design, security, destructive, or captain-owned decision can change the implementation.
- `design_grounding` and `runtime_grounding` derive their targets from the project, current context, and request-scoped evidence.
  For user-visible work, use the applicable design source such as current Figma material and exercise the real user flow in the actual runtime, inspect the result, and iterate on discrepancies.
  Static tests do not substitute for applicable visual or real-flow grounding.
- `maestro` is `pass` when NSM emulator behavior is affected and must cite the applicable Maestro flow and observed result.
  It can be `not-applicable` only when that emulator behavior is outside the change.

Bind the record to the exact implementation commit after every corrective implementation commit.
The helper independently checks the branch name, clean worktree, committed HEAD, record binding, task kind and delivery mode, required verdicts, evidence presence, and detectable Spec Kit applicability.
Worker evidence alone never authorizes `READY`.
After inspecting every axis against the accepted intent and project, Firstmate runs the helper's semantic approval command with the exact reviewed HEAD.
The helper accepts approval publication and validation only from the Firstmate session that owns the home's session lock.
The approval binds both that commit and the reviewed evidence bytes, so a later commit or evidence edit requires renewed Firstmate review and approval.

## Outcome model

The helper has exactly three readiness outcomes:

- `READY` means every semantic axis is evidenced, every deterministic repository check passed, and Firstmate's semantic approval matches the current implementation commit and exact evidence record.
  Firstmate may now invoke the installed no-mistakes skill on the same worker through `harness-adapters`.
- `NOT_READY` means implementation evidence or a deterministic prerequisite is incomplete.
  Do not start no-mistakes.
  Return the task to the same implementation worker, correct the work, commit it, update the record's HEAD and evidence, and check again.
  If the missing item is an unresolved higher-authority decision, use the existing `needs-decision` lifecycle rather than guessing.
- `ERROR` means the record, task identity, endpoint, or helper environment is malformed or unreadable.
  Preserve the work, report the concrete error to Firstmate, and do not start no-mistakes.

A failed preflight is not a review finding and must never be handed to no-mistakes with the hope that fix rounds will complete the feature.

## Starting and supervising validation

Immediately before invoking the worker's no-mistakes skill, Firstmate checks the durable record and approval itself and proceeds only on `READY` for the current HEAD.
After the worker starts AXI, Firstmate uses the helper's monitor reconciliation entry point.
If the run is not visible yet, keep supervising the worker and reconcile again after AXI reports its run.
Reconcile again during recovery, at material validation transitions, and before teardown.

The originating worker remains the only pipeline driver.
It alone issues AXI run and response calls, reads every synchronous result, and escalates ask-user findings through Firstmate under the existing authority contract.
The monitor is never sent input, never answers a gate, never edits the branch, and never starts a native pipeline agent.

## Herdr visibility boundary

For a Herdr task, reconciliation obtains the exact run from AXI in the recorded worktree and accepts it only when branch and code identity match the task.
It then creates one unfocused tab in the task's exact recorded workspace and launches the supported attach TUI bound by explicit run id.
The journal records response-derived session, workspace, tab, and pane ids and prevents a second surface for the same run.
Labels are display only and never identity or cleanup authority.

The attach TUI exposes pipeline phases, logs, findings, tests, gates, and progress.
The native pipeline agent remains a headless no-mistakes subprocess and does not become an ordinary interactive Herdr Codex worker.
The installed attach command currently has no read-only flag, so Firstmate treats the pane as presentation only and never routes keystrokes or decisions to it.

Reconciliation retires the presentation pane only after the exact run is terminal and the journal, topology, process argv, non-active focus, and confirmed-gone checks all agree.
A missing exact pane can be recreated only after positive absence.
An ambiguous, active, repurposed, or unconfirmed pane is preserved and blocks duplicate creation or teardown until inspected.
If tab creation loses its response, the attempt journal identifies the exact session, workspace, random token, and requested label for Firstmate to inspect.
After Firstmate preserves or retires any resulting presentation pane in Herdr's UI, `monitor-clear-attempt` clears only that token-matched attempt journal so reconciliation can safely resume.
The recovery command never discovers, closes, sends input to, or otherwise mutates a pane because a lost response cannot provide exact native pane authority.
This is deliberately reconciliation-driven rather than a second background lifecycle controller: after a Firstmate restart or while a run changes state, visibility and retirement advance on the next required reconcile call.

For tmux, Zellij, Orca, and cmux, the attach projection is not applicable in this workflow.
Their task panes and existing backend-specific supervision remain unchanged; do not invent an unverified split, tab, terminal, or workspace lifecycle merely for symmetry.

## Early feedback

Prefer project-native analysis, Spec Kit, focused tests, and applicable design/runtime evidence for early feedback.
The current AXI surface offers step skipping, but not a safe read-only preview contract: a partial run is still a real pipeline run, can take branch custody, incurs review startup cost, and can enter mutating fix rounds after a response.
The attach TUI observes or interacts with an existing run; it is not an early-feedback mode.
Do not recommend a partial AXI run by default.
Only try one as an explicitly authorized experiment, and treat it as a real custody-taking run that may need full recovery and later full validation.
