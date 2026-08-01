---
name: program-orchestration
description: >-
  Agent-only procedure for long-running program orchestrators.
  Use before launching, recovering, handing off, or distributing a program orchestrator or its implementation workers across hosts.
  It owns orchestrator-only model pins, evidence-gated host expansion, one-ticket worker custody, capability-based routing, and no-duplicate handoff reconciliation.
user-invocable: false
metadata:
  internal: true
---

# program-orchestration

This skill is the single owner of cross-host coordination for a long-running program secondmate.
Load it before launching, recovering, handing off, or distributing a program orchestrator or its implementation workers across hosts.
A program orchestrator is a persistent secondmate that coordinates a long-lived program; `secondmate-provisioning` remains the owner of its persistent home, charter, harness pin mechanics, inherited material, and retirement.
This skill decides program custody and worker placement, not concrete launch commands, delivery mode, evidence format, or approval authority.

## Authority map

Load `harness-adapters` before any concrete orchestrator or worker launch, recovery, runtime or model check, interrupt, exit, resume, or skill invocation.
Load `secondmate-provisioning` before creating, seeding, validating, launching, recovering, handing backlog to, or retiring the persistent secondmate home.
Use `stuck-crewmate-recovery` for a dead or unresponsive ordinary worker and preserve its recorded copy and unlanded work.
Use `paired-review` when the task meets its high-blast-radius pairing trigger, and do not invent a second program-specific review gate.
Use `diagnostic-reasoning` before scoping a reported worker bug, and use `ask-user-authority` for any finding or decision that belongs above the implementation worker.
The ordinary delivery lifecycle remains authoritative for task briefs, branches, evidence, cleanup, approval, merging, and destructive actions.
This skill references those owners instead of restating their contracts.

## Durable records and private capability knowledge

Keep the program ledger, host records, capability matrix, orchestrator pin, custody map, and handoff receipts in the effective home's private `data/`, `state/`, or `config/` surfaces.
Keep machine-specific host names, runtime versions, model availability, load limits, credentials, live-data permissions, and evidence locations out of tracked skills, docs, project memory, and `AGENTS.md`.
A host record is usable only when its capability claims have a current verification timestamp, exact runtime and model identifiers, reachable evidence storage, and a known load reading.
An unknown, expired, or contradictory host record is unavailable for remote expansion until re-verified through `harness-adapters` and the host's normal operational checks.
Do not create a new tracked schema when an existing private host or program record can carry the fact.

## Orchestrator pin boundary

Resolve the orchestrator's runtime and model pin once from the program's private record before launch or recovery.
Apply that pin only to the orchestrator process and record the exact resolved runtime and model with its launch evidence.
Resolve every implementation worker through the ordinary per-task routing precedence, even when the worker runs on the orchestrator's host.
Never inherit the orchestrator's model, runtime, effort, or host choice into a worker by default.
Changing the orchestrator pin affects only a future orchestrator launch or an explicitly authorized orchestrator replacement; it never restarts, moves, or retunes an existing implementation worker.
If a persistent-secondmate config pin and a program-specific pin both exist, `secondmate-provisioning` owns the persistent launch mechanics and this skill records which explicit pin was selected for the orchestrator.

## Candidate routing

Make one routing card for each ticket before dispatching a worker.
The card records the ticket identity, risk, dependency frontier, evidence required, live-data needs, candidate local and remote hosts, current load, selected host, selected worker profile, branch, and starting SHA.
Consider candidates in this order:

1. **Risk.** Prefer a host with a verified runtime, model, isolation boundary, and evidence capacity appropriate to the ticket's blast radius.
2. **Dependency frontier.** Prefer a host that already has the required exact checkout, dependencies, fixtures, credentials, or adjacent worker outputs without crossing an ownership boundary.
3. **Evidence capacity.** Reject a host that cannot run, retain, and expose every required test, review, diagnostic, or runtime artifact for the selected delivery path.
4. **Host load.** Among otherwise suitable hosts, prefer the least-loaded host that stays within its private recorded limit and leaves room for recovery.
5. **Live-data needs.** Prefer a host with explicitly authorized, current access to required live systems; route data-independent work away from live systems and never copy private live data merely to make a host eligible.

Choose the first host that satisfies every hard requirement, then use the later criteria to break ties rather than averaging unknown values.
A local host and a remote host are equal candidates when their verified capabilities satisfy the ticket; proximity alone is not a routing rule.
A missing capability, stale load value, absent evidence path, or unverified live-data permission removes a candidate instead of being guessed around.
A ticket that has no eligible candidate becomes a concrete blocker or captain decision under the ordinary authority rules; it is not silently downgraded.
After selecting a host, resolve the worker's concrete runtime, model, and effort through the ordinary dispatch profile and `harness-adapters` rules.
The orchestrator may recommend a route, but the worker's per-task profile remains the dispatch record of authority.

## Remote-host ramp

Treat every remote host as untrusted capacity until it completes the ramp below.

1. Verify the private host record for the required runtime, model, dependencies, evidence destination, branch transport, authentication, load limit, and live-data permissions.
2. Push the exact intended source SHA to a named remote ref and record the host, ref, and full SHA before starting any remote job.
3. Start exactly one evidence-only onboarding job on that pushed SHA.
4. Keep onboarding read-only with respect to implementation: it may inspect the environment and run bounded checks, but it does not edit product code, create an implementation branch, or claim a ticket.
5. Require onboarding evidence for runtime and model identity, checkout branch and full SHA, dependency and tool readiness, evidence capture and retention, and every required live-data permission.
6. Review the evidence against the private host record and mark the host ramped only when every item matches the pushed SHA and the recorded capability.
7. After a successful ramp, allow at most one small, bounded implementation worker on that host.

A remote implementation worker receives one ticket, one branch, the exact starting SHA, the evidence destination, and a bounded definition of done.
Do not place a second implementation worker on a newly ramped remote host merely because the first appears idle or the queue grows.
Widening remote use requires a fresh checkpoint proving the verified runtime and model, exact branch and SHA, expected current diff, and complete current evidence.
Record that checkpoint before adding capacity, changing the task size, or assigning another ticket.
A failed or incomplete checkpoint keeps the host at its current narrow capacity and routes new work elsewhere or escalates the blocker.
A high-blast-radius, destructive, irreversible, or security-sensitive expansion still follows the captain and `ask-user-authority` boundaries even when the checkpoint is green.

## One-ticket custody

Maintain the invariant `one ticket = one worker = one branch` for the lifetime of an implementation ticket.
The custody record names the ticket, worker, host, runtime, model, branch, starting SHA, current SHA, current diff identity, evidence pointers, and custody owner.
Before dispatching, search the program ledger, backlog, host records, and live structured worker inventory for an existing custody record for that ticket.
Treat an ambiguous or unreadable existing record as owned work that needs reconciliation, never as permission to dispatch a duplicate.
A worker may not pick up a second ticket until the first ticket's delivery owner records a terminal outcome or an explicit parked handoff.
A ticket branch and its completed evidence remain attached to that ticket when its host, orchestrator, or supervisor changes.
Never move an existing worker between hosts or restart it merely to change its runtime, model, effort, or load placement.
If a worker is dead, use the ordinary recovery owner to reconcile its endpoint and unlanded work before considering a successor.
If a worker is alive but its requested profile is no longer available, keep it on the current work and escalate a future-task routing change rather than interrupting it.

## Handoff and custody change

A handoff transfers supervision, not code ownership.
Before accepting custody, take a current structured inventory of every program worker in `active`, `idle`, and `parked` state.
For each worker, reconcile the ticket, host, endpoint, command-running state, branch, starting and current SHA, diff identity, completed evidence, pending evidence, and last durable owner.
Use current-state reconciliation rather than treating an append-only status event or a quiet endpoint as proof of a worker's state.
Do not declare the handoff complete while any worker lacks an inventory result or an explicit unresolved blocker.

Notify every inventoried worker of the new custody owner through the normal routed channel.
For an active worker, deliver the notification without interrupting its running command and let the command reach its normal safe point.
For an idle or parked worker, deliver the notification before assigning any new work or changing its routing record.
If notification delivery is uncertain, retain a durable pending notification and keep the old custody visible until delivery is reconciled.
Preserve each worker's branch, exact SHA, current diff, completed evidence, and evidence pointers without copying or rebasing them as part of handoff.
Do not restart a worker to make the new orchestrator or supervisor visible.
After notifications are recorded, atomically update custody ownership and make the new owner the only dispatcher for each ticket.
Re-scan for duplicate ticket assignments after the update and before dispatching anything new.
A handoff with a missing worker, conflicting branch, changed SHA, unexplained diff, or missing evidence is incomplete and becomes a blocker for reconciliation rather than a clean transfer.

## Completion checks

This procedure is complete only when the orchestrator pin is isolated from worker profiles, every dispatched ticket has exactly one custody record, every selected host has verified capability evidence, every remote host obeys the onboarding and widening limits, and every handoff worker has a reconciled inventory and custody notification.
Retain the program ledger and evidence references needed for recovery, delivery review, and cleanup under the existing private-record and delivery owners.
When a worker reaches a delivery milestone or terminal result, follow the ordinary lifecycle and approval rules instead of adding a program-specific merge, cleanup, or evidence gate.
