---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# Agent-only reference skills

These skills are not captain-invocable; load them only at their precise triggers.

- `operational-home-layout` - load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.
- `session-start-recovery` - load when the session-start digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
- `bootstrap-diagnostics` - load whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line (`MISSING:`, `MISSING_MANUAL:`, `PRESENTATION_UNAVAILABLE:`, `BACKEND_INVALID:`, `NEEDS_GH_AUTH`, `TANGLE:`, `STARTUP_MEMORY_BUDGET:`, `CREW_DISPATCH: invalid`, `FLEET_SYNC:`, `NETWORK_CHECKS:`, `HOME_SUMMARY:`, `BACKLOG_RECONCILE:`, `SECONDMATE_SYNC:`, `SECONDMATE_LIVENESS:`, `RESTORED_WORKER:`, `SECONDMATE_HANDOFF:`, `NUDGE_SECONDMATES:`, or `FMX:`), on a `check: restored-workers` wake, or when `BOOTSTRAP_INFO:` says an interrupted backlog cleanup may have left an endpoint or local copy; silence and other `BOOTSTRAP_INFO:` facts need no load.
- `diagnostic-reasoning` - load before scoping a reported bug and before acting on a diagnostic report.
- `ask-user-authority` - load before deciding any ask-user finding.
- `validation-supervision` - load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding.
- `ship-landing` - load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
- `scout-completion` - load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
- `quota-array-dispatch` - load before choosing among a matched crew-dispatch profile array from current quota-axi default TOON.
- `harness-adapters` - load before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
- `firstmate-orca` - load before switching to Orca, spawning or supervising Orca-backed work, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
- `project-management` - load before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
- `stuck-crewmate-recovery` - load when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer, and whenever a live worker reports its no-mistakes pipeline dead, unreachable, or timed out.
- `secondmate-provisioning` - load before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a secondmate home, and before editing `data/secondmates.md`.
- `captain-hold-lifecycle` - load before treating an investigation or visual review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any `RECORD DIVERGENCE` line from the wake drain.
- `away-quiet-supervision` - load whenever /afk or /quiet is invoked, an away or quiet record exists, or a marked away-supervisor message arrives.
- `process-event-sources` - load before arming a long-polling source, before registering a deterministic condition->action watch (do X as soon as Y is true), on any `procevent <adapter> <source-id> <sequence>` check wake, and on any `process-event source stranded` or `process-event source failed to start` check wake.
  Never run a registered source's blocking command yourself in a conversational turn.
- `fmx-respond` - load on an `x-mention <request_id>` `check:` wake to handle the mention, on an `x-mode-error ...` `check:` wake to report the Relay configuration blocker, on a `public-followup ...` `check:` wake or a startup-surfaced public commitment, and on any milestone or terminal wake for a Relay-linked task before posting its completion follow-up; relevant only when Relay is on.
- `firstmate-codexapp` - load before coordinating a visible Codex Desktop thread, evaluating a Codex App backend request, or reconciling Codex Desktop host-tool smoke evidence for Firstmate work.
- `firstmate-coding-guidelines` - load before changing firstmate's shared, tracked material, as defined by section 1's list, whether editing directly or briefing a crewmate for a firstmate-repo task.
