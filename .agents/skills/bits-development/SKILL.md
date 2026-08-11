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
- Nonblocking BITS monitoring uses `process-event-sources` whenever an installed source-specific adapter supports the exact wait; otherwise `AGENTS.md` sections 7 and 8 own the supervised-worker path.
- Task-level project resolution is owned by `AGENTS.md` section 7; `project-management` owns the project registry and standing delivery posture.
- Producing and validating the code change is owned by the selected delivery path in `AGENTS.md` section 7, including the no-mistakes lifecycle when selected; ordinary BITS integration begins only after that path has produced its finalized committed head and required merge request, with green checks when the path requires them.
  The narrow release-train auto-created-MR exception begins only after the exact repository, source branch, committed head, and release ticket integration branch have been verified from live sources.

## Intake and project identity

Resolve which project each completed change belongs to before touching BITS, using `AGENTS.md` section 7's task-level resolution rules and the registry managed by `project-management`, not a BITS project name guess.
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
Reuse an existing Dev Task only when it is eligible for the intended mutation and every existing identity or binding matches the live evidence for the intended stable MR identity, exact head, repository, source, and target.
Within an eligible Dev Task, reuse an already matching project or Change Card, attach only the exact intended project or Change Card that is missing, and bind only an unbound matching Change Card to the independently verified intended stable MR identity, exact head, and target.
Reject any conflicting existing binding or identity and any ineligible task; the only permitted MR-less path is the pinned release-train creation path for a Dev Task that does not yet exist, and create an object only when no correct one exists.
When the correct choice is ambiguous, stop and escalate rather than creating a parallel Dev Task that fragments the work.

## The write discipline

Every live BITS mutation uses exactly one of these two pre-write paths and then follows all shared rules below.

- Creation path: when the Dev Task does not yet exist, first read the live landscape, confirm the exact official prepare snapshot, and pin and verify the repository, source branch, exact committed head, and integration target before authorizing submission.
  If an MR already exists, read it live and verify its identity, repository, source, exact head, and target before submission; if the release-train path will auto-create the MR, defer only that MR evidence until independent post-submit readback.
  When the official owner is genuinely unavailable and the lower-level fallback has been explicitly approved, its exact dry-run payload is the confirmed prepare snapshot for this path.
- Existing-object path: when the Dev Task already exists, first re-read the full current Dev Task changes content, projects, Change Cards, `versionCode`, and MR identity, so the prepare or dry-run is built on live state.

1. Full-snapshot preservation: attach, detach, and Change Card writes rewrite a whole snapshot, so preserve `changes`, `projects`, `versionCode`, and every unknown field; never overwrite or drop a field you did not intend to change.
2. Exact dry-run review: inspect the owner's exact prepare or dry-run payload before submission, confirming repository, source, target, project type, control plane, and any existing MR identity are precisely what you intend.
3. Explicit authority for each live write: obtain the authority each live write requires under `AGENTS.md` section 7 before adding `--yes`; one approval authorizes one exact target, not a later changed one.
4. Shared immediate pre-write revalidation: immediately before every creation or mutation, independently re-read the exact live source and source head, target, task and Change Card identities or their expected absence, the applicable MR identity and MR head or its verified expected absence on the release-train auto-creation path, and every live field represented in the confirmed snapshot.
   If any identity, head, target, expected absence, or snapshot field differs from the reviewed state, invalidate the dry-run review and write authority and require a fresh applicable prepare or dry-run review and confirmation cycle.
5. Independent post-write readback: after creation or mutation, independently re-read the resulting Dev Task, every project and Change Card, MR bindings, any pre-existing or auto-created MR, and relevant pipeline or job state from BITS.
   Compare the complete intended mutation and every field confirmed or preserved from the applicable pre-write snapshot, including all changes, projects, bindings, attachments, triggers, `versionCode`, unknown fields, identities, repositories, sources, exact heads, and targets; stop before binding or continuing on any omission, no-op, or mismatch.
   API acceptance is not success until the applicable independent read confirms the complete result.
6. Timeout is outcome-unknown: treat a timeout or lost connection after transmitting a write as outcome-unknown, never as failure and never as success; reconcile by readback of the exact target before any retry, and never blindly re-issue a create.

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
- Monitoring and recovery: when an installed source-specific adapter accepted by `process-event-sources` supports the exact BITS wait, use that owner to watch the running pipeline, deploy, or run without blocking a conversational turn.
  Otherwise assign the wait to a worker through the ordinary task lifecycle in `AGENTS.md` section 7 and supervise it under section 8, so the worker may block on BITS while Firstmate's conversational turn remains free.
  After any interruption on either path, read BITS state back rather than inferring an outcome from a process exit or a single event.

## Safety boundaries

These boundaries hold regardless of yolo posture.
The project, Change Card, and unknown-field prohibition below is an invariant of this BITS development workflow, so a concrete captain request for one of those operations must leave this skill and use the operation's separate authoritative owner rather than relaxing it here.
Stage progression, deployment, merge, and rollback remain governed by the exact-action authority required by existing Firstmate rules and the captain-instruction precedence rule.

- Never remove a project or Change Card, and never overwrite an unknown snapshot field.
- Never create a duplicate Dev Task after an uncertain submit; reconcile the uncertain outcome by readback first.
- Never retarget, create, or close a merge request merely to satisfy BITS; reconcile the real MR identity instead.
- Never pass a stage, force-skip a job, continue a release, deploy to production, merge, or roll back without the exact authority that existing Firstmate rules require for that action.
- Never persist, print, or paste a BITS token, service identity, cookie, JWT, or authorization header anywhere, including status lines, briefs, commits, or captain chat.

## Captain-facing outcome reporting

Report BITS outcomes as project outcomes, following `AGENTS.md` section 9, not as raw BITS mechanics, IDs, or command output.
Lead with what landed or is ready, its consequence, and the next decision, and include the full `https://...` URL of any merge request, Dev Task, or pipeline run the captain needs to act on.
Escalate to the captain for any merge, production deploy, release continuation, rollback, stage pass, or other destructive, irreversible, or security-sensitive action before performing it, and for a credential or permission the integration needs.
