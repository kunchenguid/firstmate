---
name: bits-development
description: >-
  Agent-only procedure for delivering ByteDance-internal code through BITS and PPE.
  Load before creating, reusing, or updating a BITS Dev Task for code delivery, attaching projects, binding merge requests or Change Cards, triggering or monitoring BITS PPE, E2E, self-test, or quick-run pipelines, or beginning delivery for a deployable BITS/PPE code surface.
  Owns lifecycle applicability and ordering, exact-candidate evidence, create-versus-reuse, fresh dedicated PPE and E2E gates, the limited final no-mistakes boundary, multi-project coordination, the read-dry-run-authorize-write-readback discipline, and BITS safety; it does not own bytedcli mechanics, no-mistakes mechanics, or merge authority.
user-invocable: false
metadata:
  internal: true
---

# BITS development integration

Load this before Firstmate, or a crewmate Firstmate directs, begins delivery for a deployable ByteDance-internal code surface owned by BITS/PPE.
Also load it before creating, reusing, or updating a BITS Dev Task for code delivery, attaching projects, binding merge requests or Change Cards, or triggering or monitoring BITS PPE, E2E, self-test, or quick-run pipelines.

This skill is the single owner of Firstmate's lifecycle for delivering a committed candidate through BITS, a fresh dedicated PPE, exact-candidate E2E, and final limited no-mistakes validation.
It governs workflow and safety rather than wrapping BITS, changing no-mistakes core, or adding a fourth Firstmate delivery mode.

## Applicability and exclusions

Apply this lifecycle only when live project and BITS evidence show that the task changes deployable ByteDance-internal code with a BITS-owned source branch and a PPE runtime on which end-to-end behavior can be exercised.
Classify the task's actual surface rather than the repository name, because one project may contain both deployable and non-deployable work.

Shared IDL source repositories, their generated-code repositories, and other repositories with no deployable BITS/PPE runtime retain their existing direct-PR handling when that is their resolved delivery path.
Documentation-only and local-only work also retain their ordinary path.
Never create a PPE stage, BITS object, or runtime claim for those non-deployable surfaces merely to make this lifecycle appear complete.

## Owners this skill defers to

Every mechanical fact lives with its existing owner; this skill only selects and sequences the lifecycle.

- BITS command mechanics, exact flags, dry-run and `--yes` semantics, project types, control-plane values, dedicated-PPE creation, deployments, and test invocations are owned by the bytedcli BITS skill and current `--help`; consult them at use time and never freeze volatile syntax here.
- BITS Dev Task creation is owned by the official `bits-devops-dev-task` skill, routed through the bytedcli BITS `references/dev-task.md`; use its `prepare -> confirm -> submit` flow when it is available and installed.
- No-mistakes invocation and branch-custody mechanics are owned by the installed no-mistakes skill and current AXI help; this skill owns when that validation may start and which delivery phases it must exclude.
- Merge, delivery-mode, yolo, and captain-instruction authority are owned by `AGENTS.md` sections 1 and 7 and the captain-instruction precedence rule; this lifecycle adds no production or merge authority.
- Nonblocking BITS monitoring uses `process-event-sources` whenever an installed source-specific adapter supports the exact wait; otherwise `AGENTS.md` sections 7 and 8 own the supervised-worker path.
- Task-level project resolution is owned by `AGENTS.md` section 7; `project-management` owns the project registry and standing delivery posture.

## Candidate lifecycle

Run these stages in order for every candidate.

1. Finish the implementation, its behavioral tests where an executable contract exists, and required project documentation, then commit it on the task branch.
2. Pin the candidate identity from live evidence as the exact repository, BITS-owned source branch, committed head, target branch, and built artifact or deployment identity when BITS exposes one.
3. Deliver that exact committed head through the BITS-owned source branch, using an eligible existing Dev Task unchanged when one already owns the delivery and otherwise creating only the one missing Dev Task through the official owner.
4. Deploy that exact candidate through BITS to a fresh PPE dedicated to this candidate; never use the shared `ppe_test` environment and never deploy to production under this lifecycle.
5. Independently read back the source head, deployment, environment, and artifact identity, then run the end-to-end suite against that exact dedicated-PPE deployment.
6. Only after E2E succeeds against the verified candidate, run no-mistakes as the final validation on that same candidate.
7. Configure that final no-mistakes pass from its current help so its substantive phases are review, tests, documentation, and lint, while rebase, push, PR, and CI are excluded; no-mistakes must neither change the already-delivered candidate before review nor own BITS delivery.
8. Treat the final pass as valid only when the tested candidate identity and the validated code remain unchanged through completion.

If a no-mistakes fix changes tracked code or another build input, the changed head is a new candidate and the earlier deployment and E2E evidence no longer qualify it.
Do not edit by hand while the run owns the branch.
Complete the supported gate flow without enabling push, PR, or CI, recover branch custody through structured AXI state, commit the resulting candidate if needed, and repeat BITS source delivery, fresh dedicated-PPE deployment, exact-candidate E2E, and a new final limited no-mistakes pass.
Authorize at most two no-mistakes review fix rounds across one delivery task; if another review fix is requested, stop and escalate rather than extending the loop.
The implementation worker never answers its own ask-user finding; `AGENTS.md` section 7 and `ask-user-authority` own that decision path.

## Intake and exact identity

Resolve which project each change belongs to before touching BITS, using `AGENTS.md` section 7's task-level resolution rules and the registry managed by `project-management`, not a BITS project-name guess.
Confirm that implementation is complete and committed, the intended source and target branches are settled, and the candidate head is readable locally and from every live source that already claims it.
An already-open MR may be evidence but is not a prerequisite for starting BITS-owned delivery.

Gather the authoritative evidence for every change in the set before any decision:

- the exact repository, BITS project, BITS-owned source branch, committed source head, and intended target branch;
- any eligible Dev Task, project, Change Card, MR, pipeline, PPE, deployment, and E2E identities already present;
- for a release-train bugfix, the release ticket and its integration branch;
- the candidate's build or artifact identity whenever BITS exposes it.

Read this evidence from the live forge and BITS, never from memory or a stale status line.
Any branch movement or identity mismatch invalidates the dependent prepare, deployment, E2E, or final-validation evidence.

## Create versus reuse

Read the current landscape first with the read-only BITS surfaces owned by the bytedcli BITS skill, including Dev Tasks, changes content, project lists, Change Cards, pipelines, runs, deployments, and tests.

An eligible existing Dev Task owns the delivery when its live repository, project, source branch, target, and active pipeline scope all match the candidate and it has no conflicting identity or binding.
Reuse that Dev Task unchanged.
Do not create another Dev Task, create or retarget an MR, add or replace an MR binding, attach another project, or add another Change Card merely to restate delivery the eligible task already owns.
Use its existing source branch and verified delivery objects for the candidate, then proceed to the dedicated-PPE lifecycle.

When a superficially related Dev Task conflicts or cannot be proven eligible, stop rather than mutating it into eligibility or creating a parallel task.
When no eligible Dev Task exists, create exactly one through the official prepare flow after proving the expected absence and obtaining the required write authority.
Within that creation snapshot, include only the exact intended projects, branches, and Change Cards needed for this delivery, and let a verified release-train path create an MR only when that platform workflow requires it.
Never create, retarget, close, or bind an MR merely to satisfy BITS.

## Write discipline

Every live BITS mutation follows all rules below.

1. Full-snapshot preservation: any write that replaces a whole snapshot preserves `changes`, `projects`, `versionCode`, and every unknown field; never overwrite or drop a field you did not intend to change.
2. Exact prepare or dry-run review: inspect the owner's exact payload before submission, confirming repository, source, target, project type, control plane, dedicated environment, candidate head, and existing identities are precisely intended.
3. Explicit authority for structural or production-sensitive writes: obtain the authority `AGENTS.md` requires before adding `--yes`; one approval authorizes one exact target, not a later changed one.
4. Shared immediate pre-write revalidation: immediately before every creation or mutation, independently re-read the exact live source head, target, expected object presence or absence, applicable MR identity, and every live field represented in the confirmed snapshot.
5. Independent post-write readback: after every creation, source delivery, deployment, or test trigger, independently re-read the resulting Dev Task, projects, Change Cards, MR bindings, branch head, pipeline, PPE, deployment, artifact, and E2E state that the operation could affect.
6. Complete comparison: compare the intended mutation and every field confirmed or preserved from the pre-write snapshot, including unknown fields and exact identities; API acceptance is not success until independent readback confirms the complete result.
7. Timeout is outcome-unknown: after a timeout or lost connection following transmission, reconcile the exact target by readback before any retry and never blindly re-issue a create, deployment, or test run.

Bind an MR only on a path where no eligible existing Dev Task already owns delivery and the official creation workflow requires that binding.
Use its stable identity rather than a moving branch head, while verifying the MR still points at the intended repository, source, exact head, and target immediately before and after the bind.

## BITS operations

Run each operation through its owner with the discipline above; these notes state conceptual boundaries rather than syntax.

- Dev Task creation: only when no eligible task exists, use the official `bits-devops-dev-task` `prepare -> confirm -> submit` flow because it identifies projects and branches, combines repositories, submits only the confirmed snapshot, and reads back the result.
  Use lower-level `develop create` only when the official flow is genuinely unavailable and the captain approves that exact fallback.
- Multi-project coordination: combine related changes across projects and repositories into one new Dev Task through one official prepare rather than independent submits, while reusing one eligible existing Dev Task without structural additions when it already owns the complete delivery.
- Project and Change Card setup: include the exact project, branch, and card set in a new task's confirmed creation snapshot; do not attach or bind extras to an eligible existing task.
- Release-train target and MR handling: use the release ticket's pinned integration branch, and after any platform-required auto-created MR independently verify its identity, repository, source, exact head, and target before continuing.
- Source delivery: make the committed candidate the verified head of the BITS-owned source branch through the platform's owned delivery surface, never through no-mistakes push or PR stages.
- Dedicated PPE deployment: provision or select only a fresh PPE dedicated to the exact candidate, dry-run when supported, deploy, and read back candidate and environment identity before testing.
- E2E: trigger only against the verified dedicated-PPE deployment, read the complete result, and treat partial, stale, mismatched, or interrupted evidence as unproven.
- Monitoring and recovery: use an eligible `process-event-sources` adapter for a supported wait, otherwise assign and supervise the wait through `AGENTS.md`; after interruption, read BITS state rather than inferring an outcome from a process exit or one event.

Authorization of a ship task under this standing lifecycle includes the exact in-scope BITS-owned source delivery, dedicated-PPE deployment, and E2E run required to validate its candidate.
It does not authorize a shared environment, production deployment, stage force-pass, release continuation, rollback, changed target, or merge.

## Safety boundaries

These boundaries hold regardless of yolo posture.

- Never remove a project or Change Card, overwrite an unknown snapshot field, or mutate an existing Dev Task merely to make it appear eligible.
- Never create a duplicate Dev Task after an uncertain submit or when an eligible existing Dev Task already owns delivery.
- Never create, retarget, close, or bind an extra MR when the existing Dev Task owns delivery.
- Never use shared `ppe_test`; every candidate needs a fresh dedicated PPE and exact deployment readback.
- Never let no-mistakes rebase, push, open or update a PR, or own CI on the BITS path.
- Never pass a stage, force-skip a job, continue a release, deploy to production, merge, or roll back without the exact authority existing Firstmate rules require.
- Never merge a BITS MR before exact-candidate PPE E2E and final candidate-unchanged no-mistakes validation have both succeeded.
- Never merge a BITS MR on yolo alone; the captain must explicitly authorize that merge as a separate action.
- Never persist, print, or paste a BITS token, service identity, cookie, JWT, or authorization header anywhere, including status lines, briefs, commits, or captain chat.

## Captain-facing outcome reporting

Report BITS outcomes as project outcomes under `AGENTS.md` section 9 rather than raw mechanics, IDs, or command output.
Lead with the candidate that reached the dedicated PPE, whether exact-candidate E2E and final no-mistakes passed, and the next decision.
Include the full `https://...` URL of any MR, Dev Task, deployment, or pipeline the captain needs to act on.
Report a ready BITS delivery only when the candidate validated by the final limited no-mistakes pass is still the exact code deployed and proven by PPE E2E.
Escalate for the separate MR merge, production deployment, release continuation, rollback, stage pass, another review fix round beyond the maximum of two, or a credential or permission the integration needs.
