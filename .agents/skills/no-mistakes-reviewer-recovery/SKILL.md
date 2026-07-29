---
name: no-mistakes-reviewer-recovery
description: >-
  Agent-only procedure for preventing and diagnosing no-mistakes review or
  document stalls when the shared reviewer is degraded.
user-invocable: false
metadata:
  internal: true
---

# no-mistakes-reviewer-recovery

Load before starting no-mistakes validation when Claude is degraded, and on a review or document step that is quiet, failed, or cancelled.
This skill owns reviewer-health preflight, the shared-daemon recovery boundary, and the evidence procedure for reviewer incidents.
It never changes a project branch, responds to a crew-owned gate, or restarts the daemon from a crewmate.

## Preflight

Treat the reviewer as independent of the task worker's harness.
Before asking a worker to start validation, inspect the installed surface with `no-mistakes axi run --help`.
If it supports a run-scoped agent override, select Codex for that run when Claude is degraded and retain the help output as the version-matched authority for its exact syntax.
Do not infer an override from a global configuration file or from a newer release announcement.

When an override is unavailable, establish Claude health from both `claude auth status --json` and `quota-axi --json`.
Authentication alone does not establish available capacity.
Treat an unauthenticated result, an unavailable or stale quota source, an exhausted effective Claude availability, or a weekly window materially ahead of pace as degraded for a new reviewer run.

If Claude is degraded and no run-scoped override exists, do not start a validation run that may select Claude.
The firstmate may route the shared daemon to Codex only after it has confirmed that no lane has an active pipeline run.
That controlled recovery is: make the global no-mistakes agent setting Codex-only, restart the shared daemon once, run `no-mistakes doctor`, and record that the daemon was restarted to apply the routing change.
Never perform that recovery while any lane is active, and never ask a crewmate to perform it.
If there is active work, surface a blocked reviewer route rather than editing shared configuration or restarting the daemon.

Configuration written after the daemon started is not proof that its in-memory reviewer changed.
Compare the configuration modification time with the daemon start record when diagnosing a route mismatch, then require the controlled recovery above before relying on the new setting.

## Detection and evidence

Read the attributed current-code state with `bin/fm-crew-state.sh <crew-id>`.
It renders a matching no-mistakes review or document failure as `state: failed · source: run-step`; that is the authoritative loud signal, not a quiet pane or a stale status event.
From the crew worktree recorded in `state/<crew-id>.meta`, run `no-mistakes axi status`, require its `branch` and `head` to match that worktree under the same current-code rule as `fm-crew-state.sh`, and capture its `id` as `<run-id>`.
For the exact evidence, capture `no-mistakes axi status --run <run-id>` and `no-mistakes axi logs --run <run-id> --step review --full` or the corresponding `document` log.
Record the run id, step, start and completion timestamps, selected agent sequence, and the terminal error.

A log that shows one agent killed and the fallback failing immediately with `context canceled` does not demonstrate that the fallback agent is unhealthy.
It demonstrates that the fallback inherited an already cancelled execution context.
Record the initiating cancellation or timeout separately from the fallback symptom, and do not loop restarts.

If the step is only quiet, inspect its status and log once at the configured quiet-warning threshold.
If it remains quiet on the next bounded check, report it as blocked with the run id and step rather than cancelling and recreating the run.
For a terminal failed or cancelled run, do not restart it automatically; preserve its logs and follow the task's normal recovery authority.

## Upstream gap

If the installed help lacks a run-scoped agent override, the safe fallback is shared-daemon routing only.
That limitation is an upstream capability gap, not a reason to bypass review or skip document validation.
Use the existing [run-scoped agent override proposal](https://github.com/kunchenguid/no-mistakes/issues/474) for retained evidence, and require that capability to preserve concurrent lane isolation.
