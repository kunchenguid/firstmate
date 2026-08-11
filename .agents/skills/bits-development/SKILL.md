---
name: bits-development
description: >-
  Agent-only procedure for integrating completed code changes into ByteDance BITS.
  Load before creating, reusing, or updating a BITS Dev Task for code delivery, attaching projects, binding merge requests or Change Cards, or triggering or monitoring BITS PPE, E2E, self-test, or quick-run pipelines.
  Owns intake, create-versus-reuse, authoritative evidence, multi-project coordination, the read-dry-run-authorize-write-readback discipline, and the BITS safety boundaries; it does not own bytedcli mechanics, merge authority, or the no-mistakes pipeline.
user-invocable: false
metadata:
  internal: true
---

# BITS development integration

Load this before Firstmate, or a crewmate Firstmate directs, creates, reuses, or updates a BITS Dev Task for code delivery, attaches projects, binds merge requests or Change Cards, or triggers or monitors BITS PPE, E2E, self-test, or quick-run pipelines.

This skill is the single owner of the Firstmate procedure for landing one or more already-completed code changes into BITS Dev Tasks and pipelines.
It governs the workflow and its safety, not the platform.
It is not a wrapper, control plane, or verifier around BITS, and it changes nothing in no-mistakes core.
When one code change or a set of related changes has reached a stable committed head with either a known merge request or a verified release-train MR auto-creation path, this skill decides how that work becomes a correct BITS Dev Task, Change Card, and pipeline run without inventing state or exceeding authority.

## Owners this skill defers to

Every mechanical fact lives with its existing owner; this skill only sequences and constrains them.

- BITS command mechanics, exact flags, dry-run and `--yes` semantics, project types, and control-plane values are owned by the bytedcli BITS skill and current `--help`; consult them at use time and never freeze volatile syntax here.
- BITS Dev Task creation is owned by the official `bits-devops-dev-task` skill, routed through the bytedcli BITS `references/dev-task.md`; use its `prepare -> confirm -> submit` flow when it is available and installed.
- Merge, delivery-mode, yolo, and captain-instruction authority are owned by `AGENTS.md` sections 1 and 7 and the captain-instruction precedence rule; this skill adds no authority and relaxes none.
- Long-poll monitoring without blocking a conversational turn is owned by `process-event-sources` and the `AGENTS.md` section 8 supervision contract.
- Project identity, registry, and delivery posture are owned by `project-management`.
- Producing and validating the code change itself is owned by the no-mistakes lifecycle in `AGENTS.md` section 7; ordinary BITS integration begins only after its green PR exists.
  The narrow release-train auto-created-MR exception begins only after the exact repository, source branch, committed head, and release ticket integration branch have been verified from live sources.

## Intake and project identity

Resolve which project each completed change belongs to before touching BITS, using the `project-management` identity rules, not a BITS project name guess.
Confirm the change is genuinely complete: it has a committed head, a settled target branch, and either an opened merge request or a release-train path that will auto-create one.
Before taking the release-train exception, pin and verify the exact repository identity, source branch, committed head, release ticket, and integration branch from live sources.
BITS integration is delivery of finished work, so do not start it for an in-flight branch whose head or target is still moving.

Gather the authoritative evidence for every change in the set before any decision, except that the release-train exception defers only the not-yet-existing MR identity until BITS creates it:

- the exact repository identity and, for an ordinary flow, merge-request identity (BITS MR iid, and the underlying forge MR when relevant);
- the source branch, the current source head, and the intended target branch;
- for a release-train bugfix, the release ticket and its integration branch.

Read this evidence from the live forge and BITS, never from memory or from a stale status line.

## Create versus reuse

Decide, per Dev Task, whether to create a new one or reuse an existing one before running any write.
Read the current landscape first with the read-only BITS surfaces (Dev Task list, changes content, project list, Change Card list, pipeline and run reads) owned by the bytedcli BITS skill.
Reuse an existing Dev Task, project, or Change Card when one already covers the exact repository, source, and target; create only when nothing correct exists.
When the correct choice is ambiguous, stop and escalate rather than creating a parallel Dev Task that fragments the work.

## The write discipline

Every live BITS mutation uses exactly one of these two pre-write paths and then follows all shared rules below.

- Creation path: for a new Dev Task or a release-train operation that auto-creates an MR, first read the live landscape, confirm the exact official prepare snapshot, and pin and verify the repository, source branch, exact committed head, and integration target before authorizing submission.
  When the official owner is genuinely unavailable and the lower-level fallback has been explicitly approved, its exact dry-run payload is the confirmed prepare snapshot for this path.
- Existing-object path: for every other existing-task mutation and every ordinary flow with a pre-existing MR, re-read the full current Dev Task changes content, projects, Change Cards, `versionCode`, and MR identity immediately before the write, so the write is built on live state.

1. Full-snapshot preservation: attach, detach, and Change Card writes rewrite a whole snapshot, so preserve `changes`, `projects`, `versionCode`, and every unknown field; never overwrite or drop a field you did not intend to change.
2. Exact dry-run review: inspect the owner's exact prepare or dry-run payload before submission, confirming repository, source, target, project type, control plane, and any existing MR identity are precisely what you intend.
3. Explicit authority for each live write: obtain the authority each live write requires under `AGENTS.md` section 7 before adding `--yes`; one approval authorizes one exact target, not a later changed one.
4. Independent post-write readback: for the creation path, independently read back the resulting Dev Task and any auto-created MR and verify task identity plus MR identity, repository, source, exact head, and target before binding or continuing; for the existing-object path, re-read the Dev Task, projects, Change Cards, MR bindings, and pipeline or job state from BITS and confirm the immutable fields match what you intended.
   API acceptance is not success until the applicable independent read confirms it.
5. Timeout is outcome-unknown: treat a timeout or lost connection after transmitting a write as outcome-unknown, never as failure and never as success; reconcile by readback of the exact target before any retry, and never blindly re-issue a create.

Bind a merge request by its stable identity, never by a moving branch head.
The BITS MR iid and the repository, source, and target it carries are the durable identity; the branch head advances underneath it.
Verify the MR still points at the head you intend at bind time, and re-verify by readback, rather than assuming the head is unchanged.

## BITS operations

Run each operation through its owner with the write discipline above; the notes here are the conceptual boundaries, not the syntax.

- Dev Task creation: use the official `bits-devops-dev-task` `prepare -> confirm -> submit` flow when it is available, because it identifies projects and branches, merges multiple projects and repositories into one Dev Task, submits only the confirmed prepare snapshot, and reads back the created result.
  Use the lower-level bytedcli `develop create` path only when the official flow is genuinely unavailable and the captain has approved that fallback; it stays a fallback, not the default entry point.
- Multi-project coordination: combine related changes across projects and repositories into one Dev Task through a single official prepare rather than several independent submits, so one intent stays one delivery.
- Project attach and reuse: reuse an already-attached project when it matches; attach a new project only with an explicit branch for code projects, preserving the full snapshot and every Change Card.
- Change Card ensure, bind, and reuse: ensure or reuse the exact card for each repository, source, and target, add only genuinely missing cards, and bind an existing MR by iid; never let an ensure or attach silently clear existing cards or projects.
- Release-train target-branch constraints and auto-created MRs: on the release-train bugfix path, the target branch is constrained to the release ticket's pinned integration branch, so let that path set the target rather than forcing a target to satisfy BITS.
  After BITS auto-creates the MR, independently read it back, verify its identity, repository, source, head, and target against the pinned evidence, and only then bind its real identity or continue.
- Pipeline and project discovery: discover the current stage, tasks, projects, pipelines, and runs through the read-only surfaces before acting; treat an incomplete or unproven discovery result as a stop, not an assumption.
- PPE, E2E, self-test, and quick-run: trigger a deployment or test run only when the captain has explicitly authorized that run, because these are live operations; dry-run first where the command supports it, confirm the exact project, type, control plane, and target, and never let one authorization cover a later changed target.
- Monitoring and recovery: watch a running pipeline, deploy, or run through the `process-event-sources` long-poll supervision path instead of blocking a conversational turn, and recover after any interruption by reading BITS state back rather than inferring an outcome from a process exit or a single event.

## Safety boundaries

These boundaries hold regardless of yolo posture; only a current, explicit, concrete captain instruction of the exact action can relax one, per the captain-instruction precedence rule, and destructive, irreversible, and security-sensitive actions still require the captain to name that exact action.

- Never remove a project or Change Card, or overwrite an unknown snapshot field, to make a write succeed.
- Never create a duplicate Dev Task after an uncertain submit; reconcile the uncertain outcome by readback first.
- Never retarget, create, or close a merge request merely to satisfy BITS; reconcile the real MR identity instead.
- Never pass a stage, force-skip a job, continue a release, deploy to production, merge, or roll back without the exact authority that existing Firstmate rules require for that action.
- Never persist, print, or paste a BITS token, service identity, cookie, JWT, or authorization header anywhere, including status lines, briefs, commits, or captain chat.

## Captain-facing outcome reporting

Report BITS outcomes as project outcomes, following `AGENTS.md` section 9, not as raw BITS mechanics, IDs, or command output.
Lead with what landed or is ready, its consequence, and the next decision, and include the full `https://...` URL of any merge request, Dev Task, or pipeline run the captain needs to act on.
Escalate to the captain for any merge, production deploy, release continuation, rollback, stage pass, or other destructive, irreversible, or security-sensitive action before performing it, and for a credential or permission the integration needs.
