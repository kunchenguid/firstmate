---
name: bits-development
description: >-
  Agent-only procedure for delivering ByteDance-internal code through BITS and PPE.
  Load before creating, reusing, or updating a BITS Dev Task for code delivery, attaching projects, binding merge requests or Change Cards, triggering or monitoring BITS PPE, E2E, self-test, or quick-run pipelines, or beginning delivery for a deployable BITS/PPE code surface.
  Owns lifecycle applicability and ordering, exact-candidate evidence, create-versus-reuse, fresh dedicated PPE and browser-started E2E gates, the limited final no-mistakes boundary, multi-project coordination, the read-dry-run-authorize-write-readback discipline, and BITS safety; it does not own bytedcli mechanics, no-mistakes mechanics, or merge authority.
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

- Maintained `bytedcli` is the automation surface for every BITS read and every non-browser BITS mutation it supports.
- BITS command mechanics, exact flags, dry-run and confirmation semantics, project types, control-plane values, dedicated-PPE creation, deployments, and test reads are owned by the bytedcli skill, its BITS reference, and current `bytedcli bits ... --help`; consult them at use time and never freeze volatile syntax here.
- Never use or reinstall removed `bitscli`, including for a Dev Task operation that an older reference still routes to it.
- BITS Dev Task creation and reuse use the maintained `bytedcli bits develop` surface and its current help.
- Browser-started E2E is the sole browser mutation in this lifecycle.
- Reuse the already running authenticated GUI Chrome through installed `playwright-core` over CDP at `127.0.0.1:9333`; do not launch another browser, use `chrome-devtools-axi`, install an extension, or change browser configuration.
- Use read-only browser inspection only when the official structured `bytedcli` response does not expose configuration required for the decision or readback.
- No-mistakes invocation and branch-custody mechanics are owned by the installed no-mistakes skill and current AXI help; this skill owns when that validation may start and which delivery phases it must exclude.
- Merge, delivery-mode, yolo, and captain-instruction authority are owned by `AGENTS.md` sections 1 and 7 and the captain-instruction precedence rule; this lifecycle adds no production or merge authority.
- Nonblocking BITS monitoring uses `process-event-sources` whenever an installed source-specific adapter supports the exact wait; otherwise `AGENTS.md` sections 7 and 8 own the supervised-worker path.
- Task-level project resolution is owned by `AGENTS.md` section 7; `project-management` owns the project registry and standing delivery posture.

## Candidate lifecycle

Run these stages in order for every candidate.

1. Finish the implementation, its behavioral tests where an executable contract exists, and required project documentation, then commit it on the task branch.
2. Pin the candidate identity from live evidence as the exact repository, local committed head, intended target branch, and eligible Dev Task or expected absence.
3. Create or reuse the eligible Dev Task through maintained `bytedcli`, then identify the BITS-owned source branch for every repository without guessing from local branch names.
4. Deliver each exact candidate commit to its corresponding remote BITS-owned source branch, then independently read the remote source head and require exact equality before any deployment.
5. Revalidate the complete deployment snapshot, apply the default control plane `I18N-TT`, skip BOE, select `Singapore-Central`, and create a fresh PPE dedicated to the exact candidate unless a current explicit captain instruction overrides one of those defaults for this task.
6. Deploy only after the source-head and deployment-snapshot revalidation succeeds; never use the shared `ppe_test` environment and never deploy to production under this lifecycle.
7. Independently read back the PPE, deployment, artifact, region, control plane, BOE setting, and deployed candidate identities, then start the end-to-end test task once through the authenticated BITS browser UI against that exact deployment.
8. Read back the browser-started task and pipeline-run identity and monitor that exact run to a completed successful result; a skipped generic E2E atom inside a pipeline is not proof that the browser-started task passed.
9. Only after E2E succeeds against the verified candidate, run no-mistakes as the final validation on that same candidate.
10. Configure that final no-mistakes pass from its current help so its substantive phases are review, tests, documentation, and lint, while rebase, push, PR, and CI are excluded; no-mistakes must neither change the already-delivered candidate before review nor own BITS delivery.
11. Treat the final pass as valid only when the tested candidate identity and the validated code remain unchanged through completion.

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

- the exact repository, BITS project, BITS-owned source branch, local committed candidate, independent remote source head, and intended target branch;
- any eligible Dev Task, project, Change Card, MR, pipeline, PPE, deployment, and E2E identities already present;
- for a release-train bugfix, the release ticket and its integration branch;
- the complete deployment snapshot, including control plane, BOE setting, region, PPE identity, project configuration, and every unknown field;
- the candidate's build, artifact, and deployed revision identity whenever BITS exposes them.

Read this evidence from the live forge and BITS, never from memory or a stale status line.
Record which source directly proves each fact, label any inference, and preserve a field as unknown when neither maintained `bytedcli` nor permitted read-only browser inspection exposes it.
Any branch movement or identity mismatch invalidates the dependent prepare, deployment, E2E, or final-validation evidence.

## Create versus reuse

Read the current landscape first with the read-only BITS surfaces owned by the bytedcli BITS skill, including Dev Tasks, changes content, project lists, Change Cards, pipelines, runs, deployments, and tests.

An eligible existing Dev Task owns the delivery when its live repository, project, source branch, target, and active pipeline scope all match the candidate and it has no conflicting identity or binding.
Reuse that Dev Task unchanged.
Do not create another Dev Task, create or retarget an MR, add or replace an MR binding, attach another project, or add another Change Card merely to restate delivery the eligible task already owns.
Use its existing source branch and verified delivery objects for the candidate, then proceed to the dedicated-PPE lifecycle.

When a superficially related Dev Task conflicts or cannot be proven eligible, stop rather than mutating it into eligibility or creating a parallel task.
When no eligible Dev Task exists, create exactly one through maintained `bytedcli` after proving the expected absence, previewing the complete intended payload, and obtaining the required write authority.
Within that creation snapshot, include only the exact intended projects, branches, and Change Cards needed for this delivery, and let a verified release-train path create an MR only when that platform workflow requires it.
Never create, retarget, close, or bind an MR merely to satisfy BITS.

## Write discipline

Every live delivery write, including source delivery and the browser-started E2E action, follows all applicable rules below.

1. Full-snapshot preservation: any write that replaces a whole snapshot preserves `changes`, `projects`, `versionCode`, and every unknown field; never overwrite or drop a field you did not intend to change.
2. Exact prepare or dry-run review: inspect the owner's exact payload or preview before submission, confirming repository, source, target, project type, control plane, BOE setting, region, dedicated environment, candidate head, and existing identities are precisely intended.
3. Write authority: establish current task authority before every write, obtain any separate authority `AGENTS.md` requires before adding `--yes`, and treat one approval as authorizing one exact target rather than a later changed one.
4. Shared immediate pre-write revalidation: immediately before every creation or mutation, independently re-read the exact live source head, target, expected object presence or absence, applicable MR identity, and every live field represented in the confirmed snapshot.
5. Independent post-write readback: after every creation, source delivery, deployment, or test trigger, independently re-read the resulting Dev Task, projects, Change Cards, MR bindings, remote source head, pipeline, PPE, deployment, artifact, region, control plane, BOE setting, candidate identity, and E2E state that the operation could affect.
6. Complete comparison: compare the intended mutation and every field confirmed or preserved from the pre-write snapshot, including unknown fields and exact identities; API acceptance is not success until independent readback confirms the complete result.
7. Timeout is outcome-unknown: after a timeout or lost connection following transmission, reconcile the exact target by readback before any retry and never blindly re-issue a create, deployment, or test run.

Bind an MR only on a path where no eligible existing Dev Task already owns delivery and the official creation workflow requires that binding.
Use its stable identity rather than a moving branch head, while verifying the MR still points at the intended repository, source, exact head, and target immediately before and after the bind.

## BITS operations

Run each operation through its owner with the discipline above; these notes state conceptual boundaries rather than syntax.

- Dev Task creation: only when no eligible task exists, use maintained `bytedcli` to prepare or preview one complete task, confirm its projects and branches, submit only that confirmed snapshot, and read back the result.
- Multi-project coordination: combine related changes across projects and repositories into one new Dev Task through one confirmed creation rather than independent submits, while reusing one eligible existing Dev Task without structural additions when it already owns the complete delivery.
- Project and Change Card setup: include the exact project, branch, and card set in a new task's confirmed creation snapshot; do not attach or bind extras to an eligible existing task.
- Release-train target and MR handling: use the release ticket's pinned integration branch, and after any platform-required auto-created MR independently verify its identity, repository, source, exact head, and target before continuing.
- Source delivery: make each committed candidate the exact remote head of its BITS-owned source branch through the platform's owned delivery surface, independently read that remote head, and stop on any mismatch; never route it through no-mistakes push or PR stages.
- Deployment defaults: use `I18N-TT`, skip BOE, and use `Singapore-Central`; a current explicit captain instruction may override a named default for one exact task but does not grant production, shared-environment, stage-pass, or merge authority.
- Dedicated PPE deployment: create only a fresh PPE dedicated to the exact candidate, preview or dry-run when supported, revalidate every project and deployment field plus each remote source head, deploy, and read back the complete environment and candidate identity before testing.
- Browser-started E2E: immediately before the one browser write, preview and verify the exact Dev Task, selected pipeline, dedicated PPE, deployed candidate heads, `I18N-TT`, skipped BOE, and `Singapore-Central`, subject only to an explicit task-local captain override already recorded in that snapshot.
- Browser-started E2E: use only the existing authenticated GUI Chrome CDP session, never a `bytedcli` quick-run or test-trigger mutation, trigger the end-to-end self-test action once, capture its returned task and pipeline-run identity, read it back independently, and monitor that exact identity to completion.
- E2E proof: distinguish the browser-started task result from optional or generic in-pipeline E2E atoms, and treat a skipped atom, partial result, stale run, mismatched candidate, interruption, or unproved field as failure to establish the gate.
- Monitoring and recovery: use an eligible `process-event-sources` adapter for a supported wait, otherwise assign and supervise the wait through `AGENTS.md`; after interruption, read BITS state rather than inferring an outcome from a process exit or one event.

Authorization of a ship task under this standing lifecycle includes the exact in-scope BITS-owned source delivery, dedicated-PPE deployment, and E2E run required to validate its candidate.
It does not authorize a shared environment, production deployment, stage force-pass, release continuation, rollback, changed target, or merge.

## Safety boundaries

These boundaries hold regardless of yolo posture.

- Never remove a project or Change Card, overwrite an unknown snapshot field, or mutate an existing Dev Task merely to make it appear eligible.
- Never use or reinstall `bitscli`, use an alternate automation browser, or use the browser for a BITS mutation other than the one authenticated E2E start.
- Never create a duplicate Dev Task after an uncertain submit or when an eligible existing Dev Task already owns delivery.
- Never create, retarget, close, or bind an extra MR when the existing Dev Task owns delivery.
- Never mutate an unrelated object, guess a retry after an unknown outcome, or continue from an unproved identity.
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
