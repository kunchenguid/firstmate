# pstack playbooks for Firstmate

A playbook is a sequence, not a suggestion list.
Choose exactly one primary playbook and record every intentional omission with a reason.
The playbook routes to existing Firstmate owners and never grants merge, deploy, publish, or destructive authority.

## Investigation

Use for how, why, architecture questions, and diagnosis requests that do not yet authorize code changes.

1. Freeze the question, current source, fixed point, and non-goals.
2. Inspect project rules, source, runtime, documentation, history, and external evidence in authority order.
3. Run read-only probes that distinguish competing explanations.
4. Preserve contradictions, null results, and uncertainty.
5. Deliver a cited model and the safest next action.

A scout report is the deliverable unless implementation is separately authorized.

## Bug fix

Use for a reported defect or a diagnostic report that the current task authorizes fixing.

1. Load [`diagnostic-reasoning`](../../diagnostic-reasoning/SKILL.md) and reproduce on the closest real surface.
2. Trace the symptom to the owning seam and inspect every relevant caller.
3. Add a regression that fails for the old behavior when a focused check is practical.
4. Apply the smallest root-cause correction.
5. Run focused checks, the proportional repository gates, and the original path again.
6. Read back changed external state when the defect crosses a boundary.
7. Review the exact head read-only before declaring it ready.

## Feature or refactor

Use for behavior additions or behavior-preserving structural changes.

1. Name the user outcome, data shape, authority, and non-goals.
2. Inspect analogous code, callers, tests, and current runtime behavior.
3. Load [`implement-spec`](../../implement-spec/SKILL.md) when two or more tasks have dependency edges.
4. Build one vertical slice with a failing acceptance check when practical.
5. Implement the smallest complete slice and exercise success, error, and recovery states.
6. Review the exact head and reverify any accepted correction.

Do not turn a refactor into a feature or a feature into a rewrite without a new scope decision.

## Performance

Use for a measured user-visible slowdown or a deliberate improvement loop.

1. Define the symptom, metric, environment, and baseline.
2. Capture a trace or profile instead of guessing from source shape.
3. Locate the dominant bottleneck and state the competing explanation.
4. Change one owning seam.
5. Re-measure against the baseline and check adjacent behavior.
6. Keep the change only when the improvement is material and repeatable.

A single faster sample is not a performance result.

## Runtime or trace forensics

Use for a live symptom, crash, profile, trace, heap snapshot, or other captured runtime artifact.

1. Freeze the time window, environment, deployment or artifact hash, and current head.
2. Collect bounded evidence without mutation.
3. Correlate logs, metrics, traces, process state, source, and history as available.
4. Test competing explanations and separate correlation from mechanism.
5. Report diagnosis, confidence, impact, and the safest next action.

Forensics remain read-only until a separate implementation decision exists.

## Prototype

Use for an empirical design choice where two or three cheap alternatives can answer the question.

1. State the decision and at most three observable criteria.
2. Build materially distinct candidates in isolated copies or output directories.
3. Exercise them with realistic content or data.
4. Compare the complete candidates side by side.
5. Select, reject, or preserve uncertainty with evidence.
6. Delete or contain throwaway work only under the existing cleanup authority.

A prototype is not production code and does not authorize a visual or product decision that belongs to the Captain.

## Evaluation

Use for a skill, prompt, routing, or implementation comparison.

1. Freeze candidates, baseline, corpus, rubric, and pass criteria before running.
2. Include positive, negative, adversarial, and boundary cases.
3. Separate deterministic checks from model judgment.
4. Count every requested run and retain failures and dropouts.
5. Aggregate results programmatically and inspect the artifacts.
6. Promote only against the predeclared criteria.

Several workers using the same configured model are not a multi-model evaluation panel.

## Verification harness

Use [`project-verification-harness`](../../project-verification-harness/SKILL.md) when tests or builds are green but the real product behavior is not repeatably observable.
Create or maintain the project-local driver, Feature Map, fixtures, receipts, and deliberate-break proof before widening autonomy or parallelism.

## PR readiness

Use before a task reports a PR as ready.

1. Pin the base and exact head.
2. Read the complete diff and relevant checks.
3. Run the focused behavior proof and proportional repository gates.
4. Reproduce any alleged baseline failure at the pinned point.
5. Perform a fresh read-only review of the exact head.
6. Correct only authorized findings and verify the new head.
7. Read back the PR head, body, and checks after an external write.

Use `bin/fm-pr-check.sh` for Firstmate's PR record and watcher integration.
Do not use pstack language as a substitute for the selected delivery path.

## Multi-phase delivery

Use for work spanning dependent tasks, PRs, migrations, or durable checkpoints.

1. Build a dependency graph with one owner, artifact, acceptance check, verification, and rollback boundary per phase.
2. Persist the graph in the existing Firstmate backlog and task instructions.
3. Advance only after the preceding phase's artifact and proof reconcile with current source.
4. Keep each phase independently reviewable.
5. Stop at authority, safety, or product decisions instead of guessing.

Load [`implement-spec`](../../implement-spec/SKILL.md) for the dependency graph.

## Session pickup or safe pause

Use when resuming prior work or making it restartable.

1. Reconcile the old summary against the current branch, live process, files, and external state.
2. Identify the real owner, fixed point, artifacts, completed proof, and blockers.
3. Continue only the currently valid unit.
4. Persist the next action, authority boundary, and missing proof before pausing.
5. Produce a new receipt rather than copying an old completion claim.

Load [`stuck-crewmate-recovery`](../../stuck-crewmate-recovery/SKILL.md) when a worker has stopped responding or its endpoint is missing.

## Deliberately excluded operational playbooks

Do not port Cursor `/loop` semantics, Graphite landing, auto-merge, auto-deploy, force-push, Benny posting, or destructive worktree cleanup.
Use Firstmate's existing lifecycle, GitHub, project, frontend, and cleanup owners instead.
