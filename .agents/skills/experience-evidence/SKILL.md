---
name: experience-evidence
description: >-
  Capture a reusable evidence candidate when Firstmate semantically accepts a task result, accepts a reliable diagnosis, or receives a reliable user correction, and retrieve applicable prior evidence before intake or diagnosis when an entity, symptom, work phase, or tool surface may have occurred before.
user-invocable: false
metadata:
  internal: true
---

# Reusable experience evidence

Use this procedure to make prior task evidence findable without turning an unverified lesson into a live rule or permission.
The task's `data/<task-id>/report.md` remains the sole owner of task evidence and of every candidate derived from it.
This skill owns the candidate shape, bounded lookup, applicability check, conflict handling, and handoff to existing knowledge owners.
It does not own task records, provider execution, permissions, promotion, or a second experience store.

## When to capture

Load this skill during the same handling turn after any of these events:

- Firstmate semantically accepts a task result against its goal and acceptance evidence.
- Firstmate accepts a diagnosis whose causal claim is supported by a failed path, a proven path, and the relevant disconfirming checks.
- The user supplies a correction that changes a reusable factual or procedural claim and the correction has reliable supporting evidence.

Do not wait for `/stow` to create the first durable candidate.
Decide whether the evidence is likely to change a later intake, diagnosis, or bounded execution choice beyond this one task.
If it is not reusable, leave the task report as ordinary evidence and do not add a candidate.

When the report owner is still active and the existing task scope permits evidence maintenance, steer that owner to update the report before acceptance.
Otherwise Firstmate may maintain this private task evidence directly without changing project code or the task record.
Never create a parallel candidate file when the report can hold the candidate.

## Candidate block in the task report

Add or update one `## Reusable experience candidates` section in the report.
Each item is a fenced YAML block so fixed-string tools can locate fields while the surrounding report remains the evidence owner.
Use a stable identifier derived from the normalized claim and conditions, and update the existing item instead of appending a duplicate.

```yaml
schema: firstmate-experience-candidate.v1
id: stable-task-local-name
version: 1
status: proposed
match:
  entities:
    - exact system, dataset, component, or business object
  task_types:
    - diagnosis or operation type
  symptoms_or_phases:
    - observable symptom or work phase
  tool_surfaces:
    - exact provider, command family, synchronous or asynchronous surface
claim: concise reusable lesson
applicability:
  - condition that was actually evidenced
anti_conditions:
  - condition under which the lesson must not be applied
execution_outcome: success
lesson_validity: validated
evidence:
  report: data/<task-id>/report.md
  locators:
    - heading, artifact, or provider result that can be read back
  execution_identity:
    namespace: provider-specific namespace
    id: exact identity from the report
observed_at: YYYY-MM-DD
scope_notes: time, region, version, permission, and result limits
```

Allowed `execution_outcome` values are `success`, `failed`, `uncertain`, and `blocked`.
Allowed `lesson_validity` values are `validated`, `inferred`, `pending`, and `revoked`.
Allowed `status` values are `proposed`, `promoted`, `deprecated`, `conflict-pending-diagnosis`, and `revoked`.

Record exact execution identity only in the owning task report.
Do not copy task paths, provider run IDs, or volatile versions into a promoted general rule.
An accepted successful execution and a validated reusable lesson are separate claims, and neither grants authority to repeat the operation.
A failed or uncertain execution may support a validated negative lesson when the failure boundary is observable, but it never supports a success claim or replay authority.
A model self-rating and a user statement that an operation should succeed are not provider or server outcome evidence.

## Retrieve before intake or diagnosis

First identify a small key set from the current request: concrete entities, task type, observable symptom or phase, tool surface, and any time, region, identity, permission, or version constraints.
Use fixed-string searches for literal identifiers so punctuation in names cannot change the query.
Search in this order and stop once at most three applicable entries explain the relevant proven and failing paths.

### 1. Read already promoted owners

Search `data/learnings.md` for matching entity and mechanism terms.
Search only skill front matter for a matching JIT trigger before deciding whether to load that skill.

```bash
experience_home=${FM_HOME:?FM_HOME must name the active Firstmate home}
experience_root=${FM_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}
rg -n -F -i -- '<entity-or-mechanism>' "$experience_home/data/learnings.md"
for skills_dir in "$experience_root/.agents/skills" "$experience_home/.agents/skills"; do
  [ -d "$skills_dir" ] || continue
  for skill_file in "$skills_dir"/*/SKILL.md; do
    [ -f "$skill_file" ] || continue
    awk 'BEGIN { front=0 } /^---$/ { front++; next } front == 1 { print FILENAME ":" $0 } front >= 2 { exit }' "$skill_file"
  done
done | sort -u | rg -F -i -- '<entity-or-mechanism>'
```

Load a matched skill normally.
Treat a promoted rule as a routing lead, then follow its provenance when the current decision depends on historical execution evidence.

### 2. Locate report candidates by two routes

Match exact entities first.
Also match tool surface plus symptom or work phase, because the useful mechanism may come from a different table, endpoint, or business object.
Filter candidate blocks by those keys before bounding the result list, so common words in unrelated report prose cannot hide a relevant candidate.

```bash
candidate_reports=$(
rg -l -F -g report.md -- 'schema: firstmate-experience-candidate.v1' "$experience_home/data" |
while IFS= read -r report; do
  candidate_block=$(awk 'found && /^## / { exit } /^## Reusable experience candidates$/ { found=1 } found { print }' "$report")
  if printf '%s\n' "$candidate_block" | rg -q -F -i -- '<exact-entity>' || {
    printf '%s\n' "$candidate_block" | rg -q -F -i -- '<tool-surface>' &&
    printf '%s\n' "$candidate_block" | rg -q -F -i -- '<symptom-or-phase>'
  }; then
    printf '%s\n' "$report"
  fi
done | sed -n '1,12p'
)
printf '%s\n' "$candidate_reports" | while IFS= read -r report; do
  [ -n "$report" ] || continue
  awk 'found && /^## / { exit } /^## Reusable experience candidates$/ { found=1 } found { print }' "$report"
done
```

Rank a candidate only after checking keys as conditions rather than treating them as similarity scores.
An exact entity match does not overcome a region, permission, time, version, identity, or surface mismatch.
A mechanism match without the same entity may remain applicable when its claim and evidence are explicitly surface-level and its anti-conditions do not exclude the current case.
Do not choose a claim merely because it is newest or textually most similar.

### 3. Read the original evidence

For every retained candidate, open its owning report and read each named locator plus the surrounding qualifications.
Confirm the actual provider or server outcome, result availability, identity, input boundary, date, region, permissions, and acceptance status.
Do not infer those facts from candidate metadata alone.
Return only the few applicable claims, their boundaries, and their report paths to the active reasoning context.
Do not inject every matched report in full.

Honcho may supplement discovery only when an already available official Honcho tool can search the same entity and mechanism keys.
Treat a Honcho result only as a lead to a local report path and repeat the local report readback above before using the claim.
If Honcho is absent, unavailable, or cannot resolve a local source, continue with local lookup without blocking and do not copy its data into another store.

### 4. Empty result fallback

If no structured candidate matches, search ordinary `report.md` files with the same exact-entity and tool-plus-symptom routes and read only the small set of likely reports.
Mark any useful result as unstructured prior evidence rather than silently treating it as a validated candidate.
If that also returns nothing applicable, proceed from current evidence and say that bounded history lookup found no applicable prior evidence.

## Decide applicability, failure, and conflict

Use all of these checks before recommending a prior lesson:

- The current entity or the candidate's explicitly general mechanism scope matches.
- The task type and tool surface match at the level the claim requires.
- Region, time, version, permission, and execution identity constraints match or are irrelevant by evidence.
- The execution outcome supports the claim being made.
- The lesson validity and status permit recommendation.
- No anti-condition holds.

Exclude `revoked` and `deprecated` candidates from default recommendations while preserving them for audit.
Return `pending` or `inferred` candidates only as hypotheses that still need evidence.
Return both sides of a `conflict-pending-diagnosis` candidate with their source reports and explain which condition differs.
One failure outside an older success candidate's conditions does not revoke that success.
One success outside a negative lesson's conditions does not erase that bounded negative lesson.
Resolve a conflict only through new evidence that covers the disputed condition, and increment the report candidate's version rather than deleting history.

For a long-running query, a synchronous client timeout can validate the negative lesson that this synchronous surface supplied no resumable identity under the observed conditions.
It does not prove that the table is unreadable or that an asynchronous execution failed.
An older server-terminal success on an asynchronous surface can justify investigating reuse of that mechanism, but only if the current region, permissions, carrier, and identity handling are compatible.
It does not authorize creating a maintained asset, resubmitting an uncertain query, or claiming a new business result.

## Promotion remains with existing owners

Candidate capture makes evidence discoverable; it does not activate a rule.
During `/stow`, use this skill to interpret candidate validity and provenance, then use the `stow` skill and `AGENTS.md` knowledge-routing table for the actual destination and write boundary.
A concise fleet-local fact may be curated into `data/learnings.md`, an explicit user preference into `data/captain.md`, a reusable long procedure into an existing or approved JIT skill, and project-intrinsic knowledge through the project's ordinary `AGENTS.md` delivery path.
Routine low-risk curation follows the authority already owned by `stow`; do not add a per-fact approval gate.
Shared code, shared rules, and project changes retain their normal review and merge boundaries.

Promotion must preserve the claim, applicability boundary, anti-conditions, validity, version, and a provenance pointer while leaving exact volatile execution identity in the task report.
When newer reliable evidence supersedes a promoted claim, correct the promoted owner through its existing workflow and mark the report candidate `deprecated`, `conflict-pending-diagnosis`, or `revoked` as appropriate.

Candidate capture or retrieval never authorizes code changes, merge, permission requests, destructive cleanup, query replay, or shared-service restart.
