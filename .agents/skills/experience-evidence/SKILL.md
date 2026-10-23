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

### Capture disposition

Record one capture disposition in the owning task report for every trigger above, including when no candidate is created.
Use one `## Experience capture dispositions` section with a compact table containing the stable event key, accepted event and evidence locator, disposition, and reason.
The disposition is exactly one of `candidate:<id>`, `reason-not-reusable`, or `evidence-pending`.
An accepted success, an accepted reliable correction, or a validated negative lesson from a failed path may use `candidate:<id>` when the evidence is reusable; keep the candidate's execution outcome truthful and never turn a failed or uncertain execution into success.
Use `reason-not-reusable` when the accepted event adds no lesson beyond this task, and `evidence-pending` when acceptance or the reusable claim still lacks required evidence.
Derive the event key from the source task, event class, and stable accepted-evidence identity rather than the handling attempt, model, message time, or task duration.
Repeated handling updates the same disposition row and the same stable candidate id, if any, instead of appending another row, section, or candidate block.
When a disposition creates or updates a candidate, keep the v1 stable `data/<task-id>/report.md` evidence reference and exclude absolute worktree or transient fixture paths.
The disposition is a coverage receipt, not another candidate schema, and does not promote or activate a rule.

Do not infer a capture trigger from worker `done` or exit, a PR, merge, provider success, task age, token use, or model-call count.
These are evidence or delivery events until Firstmate accepts the result, reliable diagnosis, or evidenced correction.
A failed or blocked task with an accepted causal boundary may yield a validated negative candidate while preserving its true execution outcome.
An undiagnosed failure uses `evidence-pending`, and cancellation or archive without an already accepted reusable lesson uses `reason-not-reusable` or `evidence-pending` without changing the business disposition.

### Complex-task closure reconciliation

After Firstmate semantically accepts a complex task, reconcile the complete owning report in the same handling turn after immediate event capture.
Treat a task as complex only when its original goal and actual evidence cross responsibility, execution-identity, or result-state boundaries, recover from a real failing path, require separate multi-stage completeness proof, or disambiguate apparently conflicting sources by conditions such as version, region, namespace, or snapshot.
Elapsed time, token use, transcript length, and model-call count do not establish complexity.
Simple but reliable reusable corrections continue to trigger capture even when the task is not complex.

Closure reconciliation reads the existing dispositions and candidates, adds only an omitted accepted event, and completes an existing candidate only when the same report contains the needed evidence.
An unchanged event, claim, conditions, evidence, and conclusion is a no-op that keeps the same event key, candidate id, and version.
When new evidence changes the same candidate's claim or applicability boundary, keep one current structured candidate block under the original candidate id, increment its version, and preserve the prior version, evidence, and reason in adjacent audit prose rather than a second live candidate block.
Do not merge candidates across tasks merely because their words are similar.
Reference an existing candidate or promoted owner when claim and evidenced conditions are the same, keep different conditions separate, and preserve both sources as `conflict-pending-diagnosis` when the same conditions conflict.

Closure reconciliation may end with `reason-not-reusable` or `evidence-pending`; it never requires a candidate or skill.
It must not delay or reverse an accepted business result, clear a business gap, rewrite a failed, blocked, cancelled, or archived outcome, change cleanup eligibility, or create another review or completion gate.
If the report write or knowledge handoff fails, report that knowledge-maintenance gap separately and retain the original business outcome and evidence.
Recovery and authorized `/stow` handling may reconcile known omissions within their existing scope, but they do not scan all history, create a scheduler, or assert that an older report without a disposition was reviewed.
The observable gap between semantic acceptance and the first durable disposition remains a possible missed-capture window; treat an absent disposition as `unknown` and add no periodic scan, daemon, or second ledger unless measured losses justify a separately reviewed design.

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
Preserve the stable owning task-report reference when promoting a claim, but do not copy provider run IDs, worktree paths, transient artifact paths, or volatile versions into a promoted general rule.
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
experience_skill='<absolute loaded path to this SKILL.md>'
experience_root=${experience_skill%/.agents/skills/experience-evidence/SKILL.md}
[ -f "$experience_root/.agents/skills/experience-evidence/SKILL.md" ] || {
  printf '%s\n' 'experience-evidence: loaded skill path does not resolve its tracked Firstmate root' >&2
  exit 1
}
if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
  [ "$(realpath "$FM_ROOT_OVERRIDE")" = "$(realpath "$experience_root")" ] || {
    printf '%s\n' 'experience-evidence: FM_ROOT_OVERRIDE disagrees with the loaded skill root' >&2
    exit 1
  }
fi
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
Filter and score every structured candidate block before selecting reports, so common words or filesystem traversal order cannot hide a relevant candidate.
The score only orders which compact candidate metadata to inspect first; applicability and original evidence, never the score, decide truth.
Keep the complete ranked locator list outside the reasoning context, and expose only one page of eight compact candidates at a time.

```bash
entity_key='<exact-entity>'
task_key='<task-type>'
tool_key='<tool-surface>'
symptom_key='<symptom-or-phase>'
region_key='<region>'
boundary_key='<permission-or-identity-boundary>'
result_key='<result-state>'
candidate_ranked=$(
rg -l -F -g report.md -- 'schema: firstmate-experience-candidate.v1' "$experience_home/data" |
while IFS= read -r report; do
  awk -v report="$report" -v entity="$entity_key" -v task="$task_key" \
      -v tool="$tool_key" -v symptom="$symptom_key" -v region="$region_key" \
      -v boundary="$boundary_key" -v result="$result_key" '
    function contains(text, key) { return key != "" && index(tolower(text), tolower(key)) }
    function value(line) { sub(/^[^:]*:[[:space:]]*/, "", line); return line }
    function emit(   exact, mechanism, score, key) {
      if (!contains(block, "schema: firstmate-experience-candidate.v1")) return
      exact = contains(block, entity)
      mechanism = contains(block, tool) && contains(block, symptom)
      if (!exact && !mechanism) return
      score = exact ? 100 : 0
      if (contains(block, task)) score += 10
      if (contains(block, tool)) score += 10
      if (contains(block, symptom)) score += 10
      if (contains(block, region)) score += 10
      if (contains(block, boundary)) score += 10
      if (contains(block, result)) score += 10
      gsub(/[[:space:]]+/, " ", candidate_id)
      printf "%04d\t%s\t%s\t%s\t%s\t%s\n", score, candidate_id, status, validity, outcome, report
    }
    /^```yaml[[:space:]]*$/ { in_yaml=1; block=""; candidate_id=""; status=""; validity=""; outcome=""; next }
    in_yaml && /^```[[:space:]]*$/ { emit(); in_yaml=0; next }
    in_yaml {
      block = block $0 "\n"
      if ($0 ~ /^id:[[:space:]]*/) { candidate_id=$0; candidate_id=value(candidate_id) }
      else if ($0 ~ /^status:[[:space:]]*/) { status=$0; status=value(status) }
      else if ($0 ~ /^lesson_validity:[[:space:]]*/) { validity=$0; validity=value(validity) }
      else if ($0 ~ /^execution_outcome:[[:space:]]*/) { outcome=$0; outcome=value(outcome) }
    }
  ' "$report"
done | sort -k1,1nr -k6,6 -k2,2
)
candidate_page() {
  page_start=$1
  page_end=$((page_start + 7))
  printf '%s\n' "$candidate_ranked" | sed -n "${page_start},${page_end}p"
}
page_start=1
candidate_page "$page_start"
```

The page output is only `score`, candidate ID, status, lesson validity, execution outcome, and absolute owning-report path.
Use the IDs and paths on the current page to read only those eight candidate blocks, not every matching section.

```bash
candidate_page "$page_start" | while IFS="$(printf '\t')" read -r score candidate_id status validity outcome report; do
  [ -n "$report" ] || continue
  printf 'candidate=%s score=%s status=%s validity=%s outcome=%s report=%s\n' \
    "$candidate_id" "$score" "$status" "$validity" "$outcome" "$report"
  awk -v wanted="$candidate_id" '
    function value(line) { sub(/^[^:]*:[[:space:]]*/, "", line); return line }
    /^```yaml[[:space:]]*$/ { in_yaml=1; block=""; candidate_id=""; next }
    in_yaml && /^```[[:space:]]*$/ {
      if (candidate_id == wanted && block ~ /schema: firstmate-experience-candidate.v1/) printf "%s", block
      in_yaml=0
      next
    }
    in_yaml {
      block = block $0 "\n"
      if ($0 ~ /^id:[[:space:]]*/) { candidate_id=$0; candidate_id=value(candidate_id) }
    }
  ' "$report"
done
```

Rank a candidate only after checking keys as conditions rather than treating them as similarity scores.
Apply the conditions and anti-conditions to the eight displayed blocks, retain applicable candidates, and increment `page_start` by eight only when more evidence is still needed.
Stop after three applicable entries cover the relevant proven and failing paths or after the complete compact locator list is exhausted.
Continue past every rejected, deprecated, or revoked item, so paging never becomes a permanent pre-applicability cutoff.
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

### 4. Hand off and record consumption

For a task with applicable prior evidence, MAIN may put at most three originally verified applicable experience pointers in the ordinary brief's existing `## Firstmate spec`.
Each pointer states the candidate id and version, owning report and evidence locators, claim, applicability and anti-conditions, authority available in the present task, and the explicit boundary between the present execution identity and every historical identity.
Use the existing spec slot; do not copy full report evidence into the brief or treat the pointer as authority to submit, replay, cancel, request permission, or change an asset.

The worker reads every pointed-to original evidence locator before acting and records observable use or refusal in the destination task report.
Use one `## Experience consumption` section with a compact table containing current conditions; candidate id, version, and source locator; adopted or rejected reason; original evidence read; observable worker action; actual goal acceptance; and side effects.
Record the current execution identity only in this destination report.
Historical identities remain evidence and must never be substituted for the current identity.
When there is no current identity, or region, permission, carrier, surface, or another evidenced condition mismatches, record refusal and perform no submit, replay, cancellation, or asset mutation.
Preserve both source pointers for unresolved conflicts, qualify unknown evidence as unknown, and reject revoked or unverified candidates as applicable facts.
An older report with no consumption record is `unknown`, never proof that no experience was used.
Repeated handling of the same current task and candidate version updates the same row rather than adding another consumption artifact.
MAIN retains final applicability judgment and semantic acceptance of the current task; a worker action, provider success, or model self-rating does not establish goal acceptance by itself.
Consumption does not mean promotion.
Mark a candidate `promoted` only after its existing knowledge or skill owner has completed the normal delivery boundary and the active runtime copy can discover the result.

### 5. Empty result fallback

If no structured candidate matches, search ordinary `report.md` files with the same exact-entity and tool-plus-symptom routes and read only the small set of likely reports.
Use the following locator to score every matching path before keeping eight for evidence readback.
Choose specific result-state and identity terms from the current question, such as a provider terminal state or durable identity field, rather than relying on generic words alone.
If all eight are rejected after readback, advance the final `sed` window to `9,16p` and continue in bounded pages until an applicable report is found or the ranked list is exhausted.

```bash
unstructured_reports=$(
{
  rg -l -F -i -g report.md -- '<exact-entity>' "$experience_home/data"
  rg -l -F -i -g report.md -- '<tool-surface>' "$experience_home/data"
  rg -l -F -i -g report.md -- '<symptom-or-phase>' "$experience_home/data"
} | sort -u | while IFS= read -r report; do
  score=0
  rg -q -F -i -- '<exact-entity>' "$report" && score=$((score + 100))
  for key in '<task-type>' '<tool-surface>' '<symptom-or-phase>' '<region>' '<result-state>' '<execution-identity-term>'; do
    rg -q -F -i -- "$key" "$report" && score=$((score + 10))
  done
  printf '%04d\t%s\n' "$score" "$report"
done | sort -k1,1nr -k2,2 | sed -n '1,8p' | cut -f2-
)
printf '%s\n' "$unstructured_reports"
```

Read the selected reports and apply the same condition, anti-condition, outcome, identity, and original-evidence checks before using any claim.
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
