---
name: runtime-incident-fast-path
description: >-
  Agent-only procedure for production and runtime incidents.
  Use before creating a brief, branch, clone, working copy, implementation plan, validation run, or release for an outage, degraded production path, provider failure, or local managed-service failure.
  Owns bounded read-only triage, operational approval routing, scope-drift refusal, and escalation to the normal code workflow only after a defect is proven.
user-invocable: false
metadata:
  internal: true
---

# runtime-incident-fast-path

Load this skill at the first report of a production or runtime incident, before project management, dispatch, planning, implementation, validation, or release work begins.
Also load `diagnostic-reasoning` so the observed user path, initiating trigger, masking condition, visible symptom, proven path, counterfactual, and disconfirming evidence stay separate.

## Start with bounded triage

Do not create a branch, clone, working copy, brief, implementation plan, validation run, pull request, or deployment during triage.
Resolve the canonical repository and its origin, then use the current locally verified origin default branch as the policy and workflow authority.
Gather available production identity, runtime logs, service health, provider codes and quota state, deployment or routing identity, and local managed-service status through read-only provider or operator surfaces.
Never place a credential, token, secret, billing identifier, or raw customer data in the evidence document or incident record.
Interpret those observations under `diagnostic-reasoning`, then add an agent-adjudicated `diagnosis` object containing the supported classification, probable root cause, supporting evidence, and whether code is required.
Use `unknown` and `not yet proven` when the evidence is ambiguous; never ask the script to infer incident meaning or authority from raw observations.

Run `bin/fm-runtime-incident.py triage` with the incident id, canonical repository, concise observed symptom, a temporary structured evidence document when runtime evidence is available, and bounded `--scan-root` paths only when relevant copies may live outside the registered project directory.
The script header and `--help` own the exact commands, evidence fields, bounds, state format, and lifecycle transitions.
The command reads repositories, registered workers, and supplied runtime evidence without changing any of them, validates the deterministic lifecycle mechanics for the agent's diagnosis, and writes only the local incident ledger used by status views.

Read the complete triage result before choosing an action.
It must name the probable cause and evidence, authoritative repository and current-main working copy when one exists, whether code is required, stale or superseded copies, every active worker's exact directory, objective, age, current activity, incident relevance, unrelated or scope-drifted workers, safest next action, and exact approval required.
Treat copies with the same normalized origin as one product inventory, not as separate products because their paths differ.

## Keep the fast path narrow

Warn the captain when a worker's directory is stale or its current activity no longer matches the incident.
Do not steer, interrupt, stop, delete, move, rewrite, or clean another worker or its working copy without the captain's explicit authorization for that exact action.
Do not let a hotfix expand into an audit, pilot, fallback, architecture change, or unrelated cleanup.

When the result says `code_change_required: not yet proven`, gather only the missing runtime evidence and rerun triage.
Do not treat uncertainty, a stale registry entry, or the existence of several repository copies as proof that code must change.
When production already contains a proposed hotfix, do not recreate or redeploy that change; continue diagnosing the live path.

## No-code diagnosis

When the result says `code_change_required: no`, create no new working copy and run no code tests, CI, pull-request, or repository release process.
When `approval.required` is true, ask only for the exact operational approval named by the result, such as a paid plan change, credential creation, production configuration mutation, route correction, or managed-service restart.
Do not bundle a second operational change into that request.
After the captain gives that exact approval, record it with `approve` before performing the operation.
When `approval.required` is false, do not invoke `approve`; proceed only with the narrow repair the agent adjudicated as already within authority.
In either case, perform only the adjudicated operation through the provider's or service's supported operator surface and record the completed action with `repair`.
Then verify the complete runtime path with fresh evidence, including production identity, repaired dependency or service health, companion connectivity when relevant, and the end-user-visible request or status path.
Use `verify` only when every named check has actually passed.

## Proven code defect

When the result says `code_change_required: yes`, select the one authoritative origin and a single clean continuation from its current default branch.
Preserve every unrelated change and copy, transfer only incident-related changes, and keep the current origin default branch's policy and workflow files authoritative.
Then use the repository's normal implementation, validation, review, and release process.
After that process releases the fix, use `repair` to record the released code repair and `verify` to record fresh evidence from the complete runtime path.
The no-code fast path never authorizes a code workflow; only reproduced runtime evidence that proves the defect does.

## Status projection

`fm-fleet-view.sh`, `fm-bearings-snapshot.sh`, and `/bearings` consume the incident ledger and expose `triage → diagnosis → approval → repair → verification` with the current phase.
An approval-phase incident belongs in Captain's Call, an active diagnosis, repair, or verification belongs Underway, and an unknown incident waiting for non-captain evidence belongs Charted Next.
Do not add a fifth `/bearings` section.
