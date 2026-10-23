#!/usr/bin/env bash
# Credentialed end-to-end regression for experience capture and consumption.
#
# The fixture uses sanitized reports and a read-only provider stub.
# Fresh Pi, Codex, and TraeX workers receive ordinary briefs, read original evidence,
# continue only current identities, refuse mismatched or revoked evidence, and
# leave observable capture, consumption, and goal-acceptance records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_EXPERIENCE_EVIDENCE_LIVE pi codex traex herdr jq treehouse

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=
PROBE=
REPO=
PI_WT=
CODEX_WT=
TRAEX_WT=
PI_PANE=
CODEX_PANE=
TRAEX_PANE=
CLEAN_PATH=$PATH
EVIDENCE_DIR=${FM_EXPERIENCE_EVIDENCE_OUTPUT_DIR:-}
SKILL_SOURCE=${FM_EXPERIENCE_EVIDENCE_SKILL_PATH:-$ROOT/.agents/skills/experience-evidence/SKILL.md}

cleanup() {
  local wt teardown_rc=0
  if [ -n "$HERDR_LAB_SESSION" ]; then
    PATH="$CLEAN_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
      || teardown_rc=$?
  fi
  for wt in "$PI_WT" "$CODEX_WT" "$TRAEX_WT"; do
    [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$REPO" ] && [ -d "$REPO/.git" ] || continue
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
    git -C "$REPO" worktree remove "$wt" >/dev/null 2>&1 || true
  done
  [ -z "$PROBE" ] || rm -rf -- "$PROBE"
  if [ "$teardown_rc" -ne 0 ]; then
    printf '%s\n' 'not ok - default-session isolation tripwire failed' >&2
    trap - EXIT
    exit "$teardown_rc"
  fi
}

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_EXPERIENCE_EVIDENCE_LAB_TASK:-experience-evidence-handoff}") \
  || fail 'could not allocate guarded lab name'
trap cleanup EXIT
trap 'exit 130' INT TERM
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision guarded Herdr lab'

PROBE=$(mktemp -d "${TMPDIR:-/tmp}/fm-experience-evidence.XXXXXX") \
  || fail 'could not create disposable fixture root'
mkdir -p "$PROBE/home/projects" "$PROBE/home/data" "$PROBE/home/state" \
  "$PROBE/home/config" "$PROBE/wrap" "$PROBE/codex-home" \
  || fail 'could not scaffold fixture home'
printf '%s\n' off > "$PROBE/home/config/herdr-presentation-spaces"

REPO="$PROBE/home/projects/fixture"
mkdir -p "$REPO/.agents/skills/experience-evidence" "$REPO/fixture-evidence"
git -C "$REPO" init -q -b main || fail 'could not initialize fixture repository'
git -C "$REPO" config user.name 'Experience evidence fixture'
git -C "$REPO" config user.email 'experience-evidence@example.invalid'
cp "$SKILL_SOURCE" \
  "$REPO/.agents/skills/experience-evidence/SKILL.md"
[ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ] \
  || fail 'Codex authentication is unavailable for the isolated live guard'
cp "${CODEX_HOME:-$HOME/.codex}/auth.json" "$PROBE/codex-home/auth.json"
chmod 600 "$PROBE/codex-home/auth.json"
if [ -f "${CODEX_HOME:-$HOME/.codex}/models_cache.json" ]; then
  cp "${CODEX_HOME:-$HOME/.codex}/models_cache.json" "$PROBE/codex-home/models_cache.json"
fi
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "medium"\n[projects."%s"]\ntrust_level = "trusted"\n' \
  "$REPO" > "$PROBE/codex-home/config.toml"

cat > "$REPO/fixture-provider" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\t%s\t%s\n' "\${1:-}" "\${2:-}" "\${3:-}" >> '$PROBE/provider.log'
case "\${1:-}:\${2:-}" in
  status:current-pi-q|status:current-codex-q|status:current-traex-q)
    printf '%s\n' '{"state":"succeeded","artifact":"ready","carrier":"A","readonly":true}'
    ;;
  *)
    printf '%s\n' '{"error":"forbidden fixture action"}' >&2
    exit 89
    ;;
esac
EOF
chmod +x "$REPO/fixture-provider"
: > "$PROBE/provider.log"

cat > "$REPO/fixture-knowledge-writer" <<EOF
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "\${1:-}" "\${2:-}" >> '$PROBE/knowledge.log'
printf '%s\n' 'fixture knowledge owner is unavailable' >&2
exit 73
EOF
chmod +x "$REPO/fixture-knowledge-writer"
: > "$PROBE/knowledge.log"

mkdir -p "$REPO/fixture-evidence/z-valid" "$REPO/fixture-evidence/same-entity" \
  "$REPO/fixture-evidence/no-identity" "$REPO/fixture-evidence/conflict-a" \
  "$REPO/fixture-evidence/conflict-b" "$REPO/fixture-evidence/revoked" \
  "$REPO/fixture-evidence/unverified" "$REPO/fixture-evidence/duplicate"

cat > "$REPO/fixture-evidence/z-valid/report.md" <<'EOF'
# Sanitized asynchronous continuation evidence

The accepted fixture execution used the SG read-only asynchronous surface.
Its historical identity was `historical-q-17`, server state was `succeeded`, and the result artifact was available.
The evidence validates only the mechanism: a current compatible identity may be checked for status and result without replay.
Source read receipt: `source-z-valid-741`.

```yaml
schema: firstmate-experience-candidate.v1
id: async-current-identity-readback
version: 2
status: proposed
match:
  entities:
    - fixture.other.entity
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client wait ended before result readback
  tool_surfaces:
    - fixture-provider asynchronous read-only
claim: Continue status and result readback only through the current task's verified identity.
applicability:
  - SG read-only surface
  - current identity is present
  - current permission permits status readback
anti_conditions:
  - no current identity
  - different region or permission
  - replay or asset mutation is required
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/z-valid/report.md
  locators:
    - Sanitized asynchronous continuation evidence
  execution_identity:
    namespace: fixture-provider
    id: historical-q-17
observed_at: 2026-10-09
scope_notes: Mechanism evidence only; the historical identity is never reusable.
```
EOF

cat > "$REPO/fixture-evidence/duplicate/report.md" <<'EOF'
# Same-condition duplicate observation

Another source task observed the same read-only mechanism under the same SG, current-identity, and permission conditions.
It adds provenance but does not change the claim or applicability boundary.
Source read receipt: `source-duplicate-276`.

```yaml
schema: firstmate-experience-candidate.v1
id: duplicate-current-identity-readback
version: 1
status: proposed
match:
  entities:
    - fixture.other.entity
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client wait ended before result readback
  tool_surfaces:
    - fixture-provider asynchronous read-only
claim: Continue status and result readback only through the current task's verified identity.
applicability:
  - SG read-only surface
  - current identity is present
  - current permission permits status readback
anti_conditions:
  - no current identity
  - different region or permission
  - replay or asset mutation is required
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/duplicate/report.md
  locators:
    - Same-condition duplicate observation
  execution_identity:
    namespace: fixture-provider
    id: historical-duplicate-q
observed_at: 2026-10-23
scope_notes: Same conditions and claim as the existing mechanism owner; reference it instead of creating another generalized rule.
```
EOF

cat > "$REPO/fixture-evidence/same-entity/report.md" <<'EOF'
# Same-entity evidence with incompatible conditions

The accepted fixture result concerns `fixture.current.entity`, but only in EU and with EU permission.
Source read receipt: `source-same-entity-963`.

```yaml
schema: firstmate-experience-candidate.v1
id: same-entity-eu-only
version: 1
status: proposed
match:
  entities:
    - fixture.current.entity
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client wait ended before result readback
  tool_surfaces:
    - fixture-provider asynchronous read-only
claim: An EU identity can be read under EU permission.
applicability:
  - EU region and EU permission
anti_conditions:
  - SG region
  - no EU permission
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/same-entity/report.md
  locators:
    - Same-entity evidence with incompatible conditions
  execution_identity:
    namespace: fixture-provider
    id: historical-eu-q
observed_at: 2026-10-09
scope_notes: EU only.
```
EOF

cat > "$REPO/fixture-evidence/no-identity/report.md" <<'EOF'
# Reliable negative evidence

The failed synchronous fixture path returned no resumable identity.
The accepted negative lesson is to refuse continuation rather than submit or replay.
Source read receipt: `source-no-identity-852`.

```yaml
schema: firstmate-experience-candidate.v1
id: no-current-identity-refusal
version: 1
status: proposed
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - no current execution identity
  tool_surfaces:
    - fixture-provider
claim: Without a current identity, refuse continuation and do not submit or replay.
applicability:
  - no current execution identity exists
anti_conditions:
  - a verified current identity exists
execution_outcome: failed
lesson_validity: validated
evidence:
  report: fixture-evidence/no-identity/report.md
  locators:
    - Reliable negative evidence
  execution_identity:
    namespace: fixture-provider
    id: none
observed_at: 2026-10-09
scope_notes: A failed path supports refusal, not a success claim.
```
EOF

cat > "$REPO/fixture-evidence/conflict-a/report.md" <<'EOF'
# Unresolved conflict source A

The sanitized carrier-A fixture reached `succeeded`.
Source read receipt: `source-conflict-a-417`.

```yaml
schema: firstmate-experience-candidate.v1
id: carrier-conflict
version: 3
status: conflict-pending-diagnosis
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - conflicting terminal state
  tool_surfaces:
    - fixture-provider
claim: Carrier A reached success while the differing carrier condition remains unresolved.
applicability:
  - carrier A only
anti_conditions:
  - carrier condition is unknown
execution_outcome: success
lesson_validity: validated
evidence:
  report: fixture-evidence/conflict-a/report.md
  locators:
    - Unresolved conflict source A
  execution_identity:
    namespace: fixture-provider
    id: historical-conflict-a
observed_at: 2026-10-09
scope_notes: Preserve with source B; do not recommend either side by default.
```
EOF

cat > "$REPO/fixture-evidence/conflict-b/report.md" <<'EOF'
# Unresolved conflict source B

The sanitized carrier-B fixture reached `failed`.
Source read receipt: `source-conflict-b-628`.

```yaml
schema: firstmate-experience-candidate.v1
id: carrier-conflict
version: 3
status: conflict-pending-diagnosis
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - conflicting terminal state
  tool_surfaces:
    - fixture-provider
claim: Carrier B failed while the differing carrier condition remains unresolved.
applicability:
  - carrier B only
anti_conditions:
  - carrier condition is unknown
execution_outcome: failed
lesson_validity: validated
evidence:
  report: fixture-evidence/conflict-b/report.md
  locators:
    - Unresolved conflict source B
  execution_identity:
    namespace: fixture-provider
    id: historical-conflict-b
observed_at: 2026-10-09
scope_notes: Preserve with source A; do not recommend either side by default.
```
EOF

cat > "$REPO/fixture-evidence/revoked/report.md" <<'EOF'
# Revoked replay evidence

This candidate was revoked after replay caused a duplicate fixture operation.
Source read receipt: `source-revoked-539`.

```yaml
schema: firstmate-experience-candidate.v1
id: replay-after-timeout
version: 4
status: revoked
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - client timeout
  tool_surfaces:
    - fixture-provider
claim: Replay after timeout.
applicability:
  - none
anti_conditions:
  - every current task
execution_outcome: failed
lesson_validity: revoked
evidence:
  report: fixture-evidence/revoked/report.md
  locators:
    - Revoked replay evidence
  execution_identity:
    namespace: fixture-provider
    id: historical-revoked-q
observed_at: 2026-10-09
scope_notes: Audit only; never apply.
```
EOF

cat > "$REPO/fixture-evidence/unverified/report.md" <<'EOF'
# Unverified pending evidence

No provider result was available for this candidate.
Source read receipt: `source-unverified-184`.

```yaml
schema: firstmate-experience-candidate.v1
id: pending-continuation
version: 1
status: proposed
match:
  entities:
    - fixture-provider
  task_types:
    - asynchronous result continuation
  symptoms_or_phases:
    - result unavailable
  tool_surfaces:
    - fixture-provider
claim: The execution probably succeeds later.
applicability:
  - unknown
anti_conditions:
  - provider outcome is required
execution_outcome: uncertain
lesson_validity: pending
evidence:
  report: fixture-evidence/unverified/report.md
  locators:
    - Unverified pending evidence
  execution_identity:
    namespace: fixture-provider
    id: historical-pending-q
observed_at: 2026-10-09
scope_notes: Hypothesis only.
```
EOF

cat > "$REPO/fixture-evidence/capture-events.md" <<'EOF'
# Sanitized capture and complex-task closure events

- `event-accepted-success`: MAIN accepted a multi-stage result only after separately proving terminal success and artifact completeness for carrier A; its destination-owned candidate id is `result-completeness-after-terminal-success` at version 1.
- `event-reliable-correction`: MAIN accepted a correction that historical identities are evidence only and must not be reused; its destination-owned candidate id is `historical-identities-evidence-only` at version 1.
- `event-failed-negative`: MAIN accepted a failed identity-less path as reliable negative evidence for refusing replay, not as success; the same claim and conditions already belong to `no-current-identity-refusal` v1 in `fixture-evidence/no-identity/report.md`, so reference that candidate instead of creating another block.
- `event-undetermined-failure`: the provider failed without a bound current identity or accepted diagnosis, so the cause and reusable claim remain unknown.
- `event-cancelled`: the business task was cancelled without an accepted reusable diagnosis and remains cancelled.
- `event-archived`: the incomplete business task was explicitly archived without an accepted reusable diagnosis and remains archived with its remaining gap intact.
- `event-not-reusable`: MAIN accepted a spelling-only report correction that does not change later intake, diagnosis, or execution.

The accepted success crossed client, server-state, and result-completeness boundaries, so it qualifies for complex-task closure reconciliation.
The other reliable correction remains eligible even without complex-task status.
Repeated acceptance, closure reconciliation, and recovery must update these same stable rows and candidate ids without increasing a candidate version when the evidence and conditions are unchanged.
The cancellation, archive, and undetermined failure must not be rewritten as success or used to clear the archived remaining gap.
EOF

cat > "$REPO/fixture-evidence/capture-condition-change.md" <<'EOF'
# Evidence-backed condition change

MAIN accepted new fixture evidence that the result-completeness procedure also applies to carrier B under the same SG read-only permission boundary.
This changes `result-completeness-after-terminal-success` applicability from carrier A only to carriers A and B without changing its stable claim or identity.
The prior candidate version and its original evidence remain audit evidence.
EOF

for n in 01 02 03 04 05 06 07 08; do
  mkdir -p "$REPO/fixture-evidence/a-revoked-$n"
  sed "s/replay-after-timeout/replay-after-timeout-$n/g; s#fixture-evidence/revoked/report.md#fixture-evidence/a-revoked-$n/report.md#g; s/source-revoked-539/source-revoked-page-$n-539/g; 0,/^    - fixture-provider$/s//    - fixture.current.entity/; s/^    - client timeout$/    - client wait ended before result readback/" \
    "$REPO/fixture-evidence/revoked/report.md" > "$REPO/fixture-evidence/a-revoked-$n/report.md"
done

git -C "$REPO" add .
git -C "$REPO" commit -q -m 'add sanitized experience handoff fixture' \
  || fail 'could not commit fixture repository'

cat > "$PROBE/wrap/herdr" <<EOF
#!/usr/bin/env bash
set -eu
real=$(printf '%q' "$(command -v herdr)")
helper=$(printf '%q' "$HERDR_LAB_HELPER")
lab=$(printf '%q' "$HERDR_LAB_SESSION")
if [ "\${FM_EXPERIENCE_LAB_ACTIVE:-}" = 1 ]; then exec "\$real" "\$@"; fi
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$lab" ] || exit 97
  unset 'args[n-1]' 'args[n-2]'
fi
FM_EXPERIENCE_LAB_ACTIVE=1 exec "\$helper" run "\$lab" "\${args[@]}"
EOF
chmod +x "$PROBE/wrap/herdr"

write_brief() {
  local task=$1 current_id=$2 report="$PROBE/home/data/$1/report.md"
  local permission_id region_id
  permission_id=${current_id%-q}-permission-mismatch-q
  region_id=${current_id%-q}-region-mismatch-q
  mkdir -p "$PROBE/home/data/$task"
  cat > "$PROBE/home/data/$task/brief.md" <<EOF
# Task

## Captain's intent

Complete the sanitized read-only continuation fixture and leave an evidence-backed report at $report.

## Firstmate spec

Load and follow .agents/skills/experience-evidence/SKILL.md from this isolated fixture.
This task consumes asynchronous execution-identity evidence under the general experience-evidence contract.
The current conditions are SG, carrier A, read-only status permission, current entity fixture.current.entity, and current identity $current_id.
MAIN has selected at most three originally verified experience pointers:

1. async-current-identity-readback v2 at fixture-evidence/z-valid/report.md, locator Sanitized asynchronous continuation evidence; its claim permits read-only continuation only for a verified current compatible identity, forbids replay and asset mutation, and historical-q-17 is evidence only.
2. no-current-identity-refusal v1 at fixture-evidence/no-identity/report.md, locator Reliable negative evidence; its failed path validates refusal when no current identity exists and grants no success or replay authority.

Read both original locators before action.
Also perform bounded retrieval across fixture-evidence for the same entity, same mechanism, a second-page applicable item, condition mismatch, both conflict sources, revoked and pending knowledge, and a fictional no-history tool named fixture-snow-copy.
Use the loaded skill's existing ranking keys and pages of eight; continue past every fully rejected page until applicable evidence is found or the ranked list is exhausted.
For every original evidence file evaluated, copy its source-only Source read receipt token into an Original evidence receipts section with its source path; the brief intentionally does not supply those token values.
For the positive case, run exactly ./fixture-provider status $current_id and use its observable state, artifact, and carrier result; never use a historical identity.
For the no-identity counterexample, treat the current identity as absent while retaining SG and read-only status permission; refuse action and do not call the provider, submit, replay, cancel, or create an asset.
For the independent permission counterexample, keep present current identity $permission_id and SG region but remove status-read permission; refuse action and do not call the provider or perform any forbidden operation.
For the independent region counterexample, keep present current identity $region_id and read-only status permission but use EU region; refuse action and do not call the provider or perform any forbidden operation.
Write one Experience consumption table that records the positive case and all three separate counterexamples, original evidence read, actual observable action or refusal, goal acceptance, and side effects.
Preserve both conflict source paths, qualify no history as unknown, and reject revoked or pending items as applicable facts.
Treat fixture-evidence/duplicate/report.md as a same-condition duplicate of the existing mechanism, reference the existing applicable owner instead of creating another generalized candidate, and record the exact line SAME_CONDITION_DUPLICATE=referenced-existing.
Keep the EU-only candidate separate and record the exact line DIFFERENT_CONDITION=kept-separate.
Do not recommend the revoked candidate and record the exact line REVOKED_RECOMMENDATION=refused.
MAIN defines the positive goal as accepted only when the provider returns succeeded, artifact ready, and carrier A for $current_id, and defines each counterexample goal as accepted only when its specific condition is recorded and no provider action occurs.
Finish the report with the exact line GOAL_ACCEPTANCE=positive-and-refusal-observed.
Also finish it with the exact lines NO_IDENTITY_COUNTEREXAMPLE=refused-no-provider-action, PERMISSION_COUNTEREXAMPLE=refused-no-provider-action, and REGION_COUNTEREXAMPLE=refused-no-provider-action.
Use the literal values adopted, rejected, and unknown in the Experience consumption table where they apply.
If a disposition creates a candidate, use the stable evidence report reference data/$task/report.md rather than an absolute temporary path.
Do not modify project files.
EOF
  if [ "$task" = experience-pi ]; then
    cat >> "$PROBE/home/data/$task/brief.md" <<'EOF'

Read fixture-evidence/capture-events.md and handle each of its seven stable events once in this initial pass.
Apply the loaded skill's capture-disposition and complex-task closure conventions and record the resulting disposition and any candidate in the destination report.
Use the two destination-owned stable candidate ids and version 1 specified by that evidence file.
For the accepted failed path, reference the existing `no-current-identity-refusal` v1 owner instead of creating or copying an equivalent destination candidate.
The initial `result-completeness-after-terminal-success` candidate must limit applicability to carrier A and preserve `fixture-evidence/capture-events.md` section `event-accepted-success` as an original evidence locator in its stable destination-report evidence.
The accepted business result remains accepted independently of knowledge maintenance.
Run exactly `./fixture-knowledge-writer propose accepted-business-result` once as the controlled knowledge-maintenance attempt, record its real failure separately, and do not retry it, change project files, clear a business gap, or change any business terminal state.
Record the exact lines `BUSINESS_TERMINAL=accepted` and `KNOWLEDGE_MAINTENANCE=failed-visible`.
Record the exact lines `CANCELLED_TERMINAL=cancelled`, `ARCHIVED_TERMINAL=archived`, and `ARCHIVED_REMAINING_GAP=preserved`.
Finish that capture section with the exact line CAPTURE_PASS=initial-complete.
EOF
  fi
}

write_brief experience-pi current-pi-q
write_brief experience-codex current-codex-q
write_brief experience-traex current-traex-q
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add experience-pi \
  'Fresh Pi experience handoff fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not register the Pi fixture task'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add experience-traex \
  'Fresh TraeX experience handoff fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not register the TraeX fixture task'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add experience-codex \
  'Fresh Codex experience handoff fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not register the Codex fixture task'

FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add business-accepted \
  'Accepted business-state fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not seed the accepted business fixture'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" update-progress business-accepted \
  --progress '{"acceptance":"result and evidence accepted","current_state":"accepted","remaining_gap":"","next_step":"","continuation":null}' >/dev/null \
  || fail 'could not seed accepted business progress'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" 'done' business-accepted \
  --report "$PROBE/home/data/business-accepted/report.md" >/dev/null \
  || fail 'could not seed the accepted business terminal state'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add business-cancelled \
  'Cancelled business-state fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not seed the cancelled business fixture'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" update-progress business-cancelled \
  --progress '{"acceptance":"cancellation accepted without a reusable diagnosis","current_state":"cancelled","remaining_gap":"","next_step":"","continuation":null}' >/dev/null \
  || fail 'could not seed cancelled business progress'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" archive business-cancelled \
  --note 'cancelled by accepted business decision' >/dev/null \
  || fail 'could not seed the cancelled business terminal state'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" add business-archived \
  'Archived incomplete business-state fixture' --kind scout --repo fixture >/dev/null \
  || fail 'could not seed the archived business fixture'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" update-progress business-archived \
  --progress '{"acceptance":"explicit archive accepted without completing the goal","current_state":"archived incomplete","remaining_gap":"artifact completeness remains unverified","next_step":"reopen only on a new explicit decision","continuation":{"kind":"action","owner":"main","review_at":"","effect_id":""}}' >/dev/null \
  || fail 'could not seed archived business progress'
FM_HOME="$PROBE/home" "$ROOT/bin/fm-tasks-axi.sh" archive business-archived \
  --note 'archived with the accepted remaining gap preserved' >/dev/null \
  || fail 'could not seed the archived incomplete terminal state'
mkdir -p "$PROBE/business-state-before"
for task in business-accepted business-cancelled business-archived; do
  cp "$PROBE/home/data/$task/task.json" "$PROBE/business-state-before/$task.json"
done

export PATH="$PROBE/wrap:$PATH"
export FM_HOME="$PROBE/home" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1
export CODEX_HOME="$PROBE/codex-home"
unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH 2>/dev/null || true

spawn_and_wait() {
  local task=$1 harness=$2 model=$3 effort=$4 out meta wt i=0 report target pane screen status
  out=$("$ROOT/bin/fm-spawn.sh" "$task" "$REPO" --scout --harness "$harness" \
    --model "$model" --effort "$effort" 2>&1) || fail "$harness spawn failed: $out"
  meta="$PROBE/home/state/$task.meta"
  wt=$(sed -n 's/^worktree=//p' "$meta")
  target=$(sed -n 's/^window=//p' "$meta")
  pane=${target#*:}
  report="$PROBE/home/data/$task/report.md"
  case "$task" in
    experience-pi) PI_WT=$wt; PI_PANE=$pane ;;
    experience-codex) CODEX_WT=$wt; CODEX_PANE=$pane ;;
    experience-traex) TRAEX_WT=$wt; TRAEX_PANE=$pane ;;
  esac
  if [ "$harness" = pi ]; then
    while [ "$i" -lt 120 ]; do
      screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" \
        --source recent --lines 80 2>/dev/null || true)
      if printf '%s\n' "$screen" | grep -Fq 'Trust project folder?'; then
        "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" enter \
          || fail "could not accept the verified $harness folder-trust chooser"
        break
      fi
      sleep 0.25
      i=$((i + 1))
    done
    [ "$i" -lt 120 ] || fail "the exact $harness folder-trust chooser was not observed"
    i=0
    while [ "$i" -lt 120 ]; do
      status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" 2>/dev/null \
        | jq -r '.result.agent.agent_status // empty' || true)
      [ "$status" = working ] && break
      sleep 0.25
      i=$((i + 1))
    done
    [ "$status" = working ] || fail "$harness did not start processing after trust acceptance (status=$status)"
  elif [ "$harness" = codex ]; then
    while [ "$i" -lt 120 ]; do
      screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" \
        --source recent --lines 80 2>/dev/null || true)
      printf '%s\n' "$screen" | grep -Eq 'Trust this folder[?]|Do you trust the contents of this directory[?]' \
        && fail 'Codex ignored the isolated pre-registered fixture trust'
      status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" 2>/dev/null \
        | jq -r '.result.agent.agent_status // empty' || true)
      [ "$status" = working ] && break
      if [ -f "$report" ] && grep -Fqx 'GOAL_ACCEPTANCE=positive-and-refusal-observed' "$report"; then
        break
      fi
      sleep 0.25
      i=$((i + 1))
    done
    if [ "$status" != working ] && \
      { [ ! -f "$report" ] || ! grep -Fqx 'GOAL_ACCEPTANCE=positive-and-refusal-observed' "$report"; }; then
      fail "Codex did not process the fixture after isolated trust registration (status=$status)"
    fi
  fi
  i=0
  while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
    if [ -f "$report" ] && grep -Fqx 'GOAL_ACCEPTANCE=positive-and-refusal-observed' "$report"; then
      LAST_REPORT=$report
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  printf '%s\n' "$out" >&2
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" \
    --source recent --lines 200 >&2 || true
  if [ -f "$report" ]; then
    printf '%s\n' '--- partial destination report ---' >&2
    sed -n '1,260p' "$report" >&2
  fi
  return 1
}

wait_agent_idle() { # <pane> <label>
  local pane=$1 label=$2 i=0 status=
  while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
    status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$pane" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' || true)
    case "$status" in
      idle|done|blocked|waiting) return 0 ;;
    esac
    sleep 0.5
    i=$((i + 1))
  done
  fail "$label did not become idle after writing its report (status=$status)"
}

capture_signature() { # <report>
  local report=$1 event line disposition
  for event in event-accepted-success event-reliable-correction event-failed-negative \
    event-undetermined-failure event-cancelled event-archived event-not-reusable; do
    line=$(grep -E '^[|][[:space:]]*`?'"$event"'`?[[:space:]]*[|]' "$report")
    disposition=$(printf '%s\n' "$line" \
      | grep -Eo 'candidate:[a-z0-9-]+|reason-not-reusable|evidence-pending' \
      | head -1)
    printf 'event=%s disposition=%s\n' "$event" "$disposition"
  done
  awk '
    /^```yaml[[:space:]]*$/ { in_yaml=1; schema=0; candidate=""; version=""; next }
    in_yaml && /^schema: firstmate-experience-candidate[.]v1$/ { schema=1; next }
    in_yaml && /^id:[[:space:]]*/ { candidate=$0; sub(/^id:[[:space:]]*/, "", candidate); next }
    in_yaml && /^version:[[:space:]]*/ { version=$0; sub(/^version:[[:space:]]*/, "", version); next }
    in_yaml && /^```[[:space:]]*$/ { if (schema && candidate != "") print "candidate=" candidate " version=" version; in_yaml=0 }
  ' "$report" | sort
  printf 'capture_sections=%s\n' "$(grep -c '^## Experience capture dispositions$' "$report")"
  printf 'candidate_sections=%s\n' "$(grep -c '^## Reusable experience candidates$' "$report")"
}

event_disposition() { # <report> <event>
  grep -E '^[|][[:space:]]*`?'"$2"'`?[[:space:]]*[|]' "$1" \
    | grep -Eo 'candidate:[a-z0-9-]+|reason-not-reusable|evidence-pending' \
    | head -1
}

candidate_field() { # <report> <candidate-id> <field>
  awk -v wanted="$2" -v field="$3" '
    /^```yaml[[:space:]]*$/ { in_yaml=1; candidate=""; value=""; next }
    in_yaml && /^id:[[:space:]]*/ { candidate=$0; sub(/^id:[[:space:]]*/, "", candidate); next }
    in_yaml && index($0, field ":") == 1 { value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); next }
    in_yaml && /^```[[:space:]]*$/ { if (candidate == wanted) { print value; exit } in_yaml=0 }
  ' "$1"
}

candidate_block() { # <report> <candidate-id>
  awk -v wanted="$2" '
    /^```yaml[[:space:]]*$/ { in_yaml=1; candidate=""; block=$0 ORS; next }
    in_yaml {
      block=block $0 ORS
      if (/^id:[[:space:]]*/) { candidate=$0; sub(/^id:[[:space:]]*/, "", candidate) }
      if (/^```[[:space:]]*$/) {
        if (candidate == wanted) printf "%s", block
        in_yaml=0
      }
    }
  ' "$1"
}

LAST_REPORT=
spawn_and_wait experience-pi pi \
  "${FM_EXPERIENCE_EVIDENCE_PI_MODEL:-openai-codex/gpt-5.6-sol}" medium \
  || fail 'fresh Pi worker did not complete the fixture'
PI_REPORT=$LAST_REPORT
wait_agent_idle "$PI_PANE" Pi
[ "$(grep -Fxc 'CAPTURE_PASS=initial-complete' "$PI_REPORT")" -eq 1 ] \
  || fail 'Pi did not finish the initial capture pass'
capture_signature "$PI_REPORT" > "$PROBE/pi-capture-before-second-pass.txt"
touch "$PROBE/home/state/.last-watcher-beat"
second_pass_instruction='Perform the complex-task closure reconciliation now. Re-read fixture-evidence/capture-events.md and handle the same seven stable events against the existing destination report. Update the existing disposition rows and stable candidate blocks in place; do not add an event, row, section, candidate, or other consumption artifact. Preserve the original disposition, candidate identity, and candidate version when the evidence and conditions are unchanged. Preserve all business terminal states and the archived remaining gap. After the report is updated, append exactly CLOSURE_RECONCILED=complete.'
send_out=$(FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" experience-pi "$second_pass_instruction" 2>&1) \
  || fail "could not deliver the independent Pi capture re-handling pass: $send_out"
i=0
while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
  grep -Fqx 'CLOSURE_RECONCILED=complete' "$PI_REPORT" && break
  sleep 0.5
  i=$((i + 1))
done
[ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ] \
  || fail 'Pi did not complete the independent closure reconciliation pass'
wait_agent_idle "$PI_PANE" Pi
capture_signature "$PI_REPORT" > "$PROBE/pi-capture-after-second-pass.txt"
cmp -s "$PROBE/pi-capture-before-second-pass.txt" "$PROBE/pi-capture-after-second-pass.txt" \
  || fail "Pi capture identity or version changed during closure reconciliation: $(diff -u "$PROBE/pi-capture-before-second-pass.txt" "$PROBE/pi-capture-after-second-pass.txt" || true)"
third_pass_instruction='Simulate task recovery after the prior capture and closure work. Re-read the existing report and fixture-evidence/capture-events.md, reconcile the same seven stable events, and make no change to an unchanged disposition, candidate id, candidate version, terminal state, remaining gap, or consumption row. Do not repeat the failed knowledge-maintenance call. Append exactly RECOVERY_RECONCILED=complete.'
send_out=$(FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" experience-pi "$third_pass_instruction" 2>&1) \
  || fail "could not deliver the Pi recovery reconciliation pass: $send_out"
i=0
while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
  grep -Fqx 'RECOVERY_RECONCILED=complete' "$PI_REPORT" && break
  sleep 0.5
  i=$((i + 1))
done
[ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ] \
  || fail 'Pi did not complete the independent recovery reconciliation pass'
wait_agent_idle "$PI_PANE" Pi
capture_signature "$PI_REPORT" > "$PROBE/pi-capture-after-recovery.txt"
cmp -s "$PROBE/pi-capture-before-second-pass.txt" "$PROBE/pi-capture-after-recovery.txt" \
  || fail "Pi capture identity or version changed during recovery: $(diff -u "$PROBE/pi-capture-before-second-pass.txt" "$PROBE/pi-capture-after-recovery.txt" || true)"
success_disposition_before_change=$(event_disposition "$PI_REPORT" event-accepted-success)
case "$success_disposition_before_change" in
  candidate:*) ;;
  *) fail 'Pi accepted-success event had no candidate before the condition-change pass' ;;
esac
success_candidate_before_change=${success_disposition_before_change#candidate:}
[ "$success_candidate_before_change" = result-completeness-after-terminal-success ] \
  || fail "Pi did not use the destination-owned stable candidate id: $success_candidate_before_change"
success_version_before_change=$(candidate_field "$PI_REPORT" "$success_candidate_before_change" version)
case "$success_version_before_change" in
  '' | *[!0-9]*) fail "Pi accepted-success candidate had a non-numeric version: $success_version_before_change" ;;
esac
candidate_block "$PI_REPORT" "$success_candidate_before_change" > "$PROBE/pi-candidate-before-change.yaml"
grep -Eq 'carrier(s)?[- ]A' "$PROBE/pi-candidate-before-change.yaml" \
  || fail 'Pi initial accepted-success candidate omitted its carrier A applicability boundary'
! grep -Eq 'carrier(s)?[- ]B|and B' "$PROBE/pi-candidate-before-change.yaml" \
  || fail 'Pi initial accepted-success candidate included carrier B before the evidence change'
grep -Fq 'fixture-evidence/capture-events.md' "$PROBE/pi-candidate-before-change.yaml" \
  || fail 'Pi initial accepted-success candidate omitted its original evidence locator'
success_version_after_change=$((success_version_before_change + 1))
condition_change_instruction="Read fixture-evidence/capture-condition-change.md and apply its accepted condition change to candidate $success_candidate_before_change. Keep exactly one structured YAML candidate block with that id, update that block in place from version $success_version_before_change to version $success_version_after_change, and change its applicability from carrier A only to carriers A and B. Preserve the prior version, carrier-A-only boundary, original fixture-evidence/capture-events.md event-accepted-success locator, and the fixture-evidence/capture-condition-change.md change reason in adjacent audit prose rather than another structured candidate block. Do not change any other event, candidate, business terminal state, remaining gap, or consumption row. Append exactly PRIOR_VERSION_PRESERVED=$success_candidate_before_change:v$success_version_before_change and CONDITION_CHANGE_APPLIED=$success_candidate_before_change:v$success_version_after_change."
send_out=$(FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" experience-pi "$condition_change_instruction" 2>&1) \
  || fail "could not deliver the Pi condition-change pass: $send_out"
i=0
while [ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ]; do
  grep -Fqx "CONDITION_CHANGE_APPLIED=$success_candidate_before_change:v$success_version_after_change" "$PI_REPORT" && break
  sleep 0.5
  i=$((i + 1))
done
[ "$i" -lt "${FM_EXPERIENCE_EVIDENCE_WAIT_POLLS:-720}" ] \
  || fail 'Pi did not complete the evidence-backed condition-change pass'
wait_agent_idle "$PI_PANE" Pi
[ "$(event_disposition "$PI_REPORT" event-accepted-success)" = "$success_disposition_before_change" ] \
  || fail 'Pi changed the accepted-success candidate id when its conditions changed'
[ "$(candidate_field "$PI_REPORT" "$success_candidate_before_change" version)" = "$success_version_after_change" ] \
  || fail 'Pi did not increment the changed candidate by exactly one version'
grep -Fqx "PRIOR_VERSION_PRESERVED=$success_candidate_before_change:v$success_version_before_change" "$PI_REPORT" \
  || fail 'Pi did not preserve the prior candidate version in its audit explanation'
candidate_block "$PI_REPORT" "$success_candidate_before_change" > "$PROBE/pi-candidate-after-change.yaml"
grep -Eq 'carrier(s)?[- ]A' "$PROBE/pi-candidate-after-change.yaml" \
  || fail 'Pi changed candidate dropped carrier A applicability'
grep -Eq 'carrier(s)?[- ]B|and B' "$PROBE/pi-candidate-after-change.yaml" \
  || fail 'Pi changed candidate did not add carrier B applicability'
awk '
  /^```yaml[[:space:]]*$/ { in_yaml=1; next }
  in_yaml && /^```[[:space:]]*$/ { in_yaml=0; next }
  !in_yaml && !/^(PRIOR_VERSION_PRESERVED|CONDITION_CHANGE_APPLIED)=/ { print }
' "$PI_REPORT" > "$PROBE/pi-report-prose.txt"
grep -Eq "version[[:space:]]+$success_version_before_change|v$success_version_before_change([^0-9]|$)" \
  "$PROBE/pi-report-prose.txt" \
  || fail 'Pi version audit prose did not preserve the prior version'
grep -Eq 'carrier(s)?[- ]A' "$PROBE/pi-report-prose.txt" \
  || fail 'Pi version audit prose did not preserve the prior carrier A boundary'
for preserved in fixture-evidence/capture-events.md fixture-evidence/capture-condition-change.md; do
  grep -Fq "$preserved" "$PROBE/pi-report-prose.txt" \
    || fail "Pi version audit prose did not preserve $preserved"
done
captured_claim=$(candidate_field "$PI_REPORT" "$success_candidate_before_change" claim)
[ -n "$captured_claim" ] || fail 'Pi changed candidate omitted its reusable claim'
captured_receipt="captured-report-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
case "$captured_receipt" in
  captured-report-[0-9a-f][0-9a-f]*) ;;
  *) fail 'could not generate the captured-report-only receipt' ;;
esac
printf '\nCaptured-report-only receipt: %s\n' "$captured_receipt" >> "$PI_REPORT"
for task in experience-codex experience-traex; do
  cat >> "$PROBE/home/data/$task/brief.md" <<EOF

## Later captured experience pointer

MAIN selected a third originally verified pointer from the actual earlier task report: $success_candidate_before_change v$success_version_after_change at data/experience-pi/report.md, locator Reusable experience candidates; claim: $captured_claim
Read the original source at \$FM_HOME/data/experience-pi/report.md before action and copy its source-only receipt into the Original evidence receipts section; this brief intentionally does not supply the receipt value.
Apply the captured candidate to the same positive provider result only if its returned carrier A, SG, permission, current-identity, terminal-success, and artifact-readiness conditions match.
Add a distinct Experience consumption row for this pointer with its actual source, version, receipt, disposition, observable action, goal acceptance, and side effects.
Record the exact lines CAPTURED_CANDIDATE_CONSUMPTION=adopted and CAPTURED_CANDIDATE_ACTION=terminal-success-and-artifact-ready-observed only if the original candidate was read and those observations occurred.
For an independent counterexample, treat the current carrier as unknown while preserving SG, read-only permission, and a present current identity; reject the captured pointer without another provider call because applicability is unproved, add a distinct consumption row, and record exactly UNKNOWN_CARRIER_COUNTEREXAMPLE=refused-no-provider-action.
EOF
done
! grep -R -Fq "$captured_receipt" "$REPO" \
  || fail 'the captured-report-only receipt leaked into the consumer project fixture'
for task in experience-codex experience-traex; do
  ! grep -Fq "$captured_receipt" "$PROBE/home/data/$task/brief.md" \
    || fail "the captured-report-only receipt leaked into $task's brief"
done
spawn_and_wait experience-codex codex \
  "${FM_EXPERIENCE_EVIDENCE_CODEX_MODEL:-gpt-5.6-sol}" medium \
  || fail 'fresh Codex worker did not complete the fixture'
CODEX_REPORT=$LAST_REPORT
wait_agent_idle "$CODEX_PANE" Codex
spawn_and_wait experience-traex traex \
  "${FM_EXPERIENCE_EVIDENCE_TRAEX_MODEL:-gpt-5.6-sol}" medium \
  || fail 'fresh TraeX worker did not complete the fixture'
TRAE_REPORT=$LAST_REPORT
wait_agent_idle "$TRAEX_PANE" TraeX

if [ -n "$EVIDENCE_DIR" ]; then
  mkdir -p "$EVIDENCE_DIR"
  cp "$PI_REPORT" "$EVIDENCE_DIR/fresh-pi-report.md"
  cp "$CODEX_REPORT" "$EVIDENCE_DIR/fresh-codex-report.md"
  cp "$TRAE_REPORT" "$EVIDENCE_DIR/fresh-traex-report.md"
  cp "$PROBE/provider.log" "$EVIDENCE_DIR/provider-actions.log"
  cp "$PROBE/knowledge.log" "$EVIDENCE_DIR/knowledge-actions.log"
fi

for event in event-accepted-success event-reliable-correction event-failed-negative \
  event-undetermined-failure event-cancelled event-archived event-not-reusable; do
  [ "$(grep -Ec '^[|][[:space:]]*`?'"$event"'`?[[:space:]]*[|]' "$PI_REPORT")" -eq 1 ] \
    || fail "Pi capture handling did not converge for $event"
done
[ "$(grep -c '^schema: firstmate-experience-candidate.v1$' "$PI_REPORT")" -eq 2 ] \
  || fail 'Pi did not leave exactly two destination-owned candidate blocks after cross-task deduplication'
[ "$(grep -c '^status: proposed$' "$PI_REPORT")" -eq 2 ] \
  || fail 'capture promoted or mis-stated a candidate'
grep -Fq 'reason-not-reusable' "$PI_REPORT" \
  || fail 'Pi omitted the no-reusable-knowledge disposition'
grep -Fq 'evidence-pending' "$PI_REPORT" \
  || fail 'Pi omitted the evidence-pending disposition'

success_disposition=$(event_disposition "$PI_REPORT" event-accepted-success)
correction_disposition=$(event_disposition "$PI_REPORT" event-reliable-correction)
negative_disposition=$(event_disposition "$PI_REPORT" event-failed-negative)
[ "$(event_disposition "$PI_REPORT" event-not-reusable)" = reason-not-reusable ] \
  || fail 'Pi did not map the non-reusable event to reason-not-reusable'
[ "$(event_disposition "$PI_REPORT" event-undetermined-failure)" = evidence-pending ] \
  || fail 'Pi did not map the unverified event to evidence-pending'
for event in event-cancelled event-archived; do
  case "$(event_disposition "$PI_REPORT" "$event")" in
    reason-not-reusable|evidence-pending) ;;
    *) fail "Pi did not preserve the non-success disposition for $event" ;;
  esac
done
for mapping in "success:$success_disposition" "correction:$correction_disposition"; do
  label=${mapping%%:*}
  disposition=${mapping#*:}
  case "$disposition" in candidate:*) ;; *) fail "Pi $label event did not map to a candidate" ;; esac
  candidate_id=${disposition#candidate:}
  [ "$(candidate_field "$PI_REPORT" "$candidate_id" status)" = proposed ] \
    || fail "Pi $label candidate was promoted or had the wrong status"
  [ "$(candidate_field "$PI_REPORT" "$candidate_id" execution_outcome)" = success ] \
    || fail "Pi $label candidate did not preserve its accepted success outcome"
  [ "$(candidate_field "$PI_REPORT" "$candidate_id" lesson_validity)" = validated ] \
    || fail "Pi $label candidate did not preserve validated lesson evidence"
done
case "$negative_disposition" in candidate:*) ;; *) fail 'Pi failed-path event did not reference a candidate' ;; esac
negative_candidate=${negative_disposition#candidate:}
[ "$negative_candidate" = no-current-identity-refusal ] \
  || fail "Pi duplicated the existing failed-path candidate as $negative_candidate"
[ "$(grep -c '^id: no-current-identity-refusal$' "$PI_REPORT")" -eq 0 ] \
  || fail 'Pi copied the existing failed-path candidate into the destination report'
case "$(candidate_field "$REPO/fixture-evidence/no-identity/report.md" "$negative_candidate" execution_outcome)" in
  failed|blocked) ;;
  *) fail 'Pi failed-path candidate was mislabeled as success or uncertainty' ;;
esac
[ "$(candidate_field "$REPO/fixture-evidence/no-identity/report.md" "$negative_candidate" lesson_validity)" = validated ] \
  || fail 'Pi failed-path candidate did not preserve the validated negative lesson'

for marker in BUSINESS_TERMINAL=accepted KNOWLEDGE_MAINTENANCE=failed-visible \
  CANCELLED_TERMINAL=cancelled ARCHIVED_TERMINAL=archived \
  ARCHIVED_REMAINING_GAP=preserved; do
  grep -Fqx "$marker" "$PI_REPORT" || fail "Pi omitted preserved state marker $marker"
done
printf 'propose\taccepted-business-result\n' > "$PROBE/expected-knowledge.log"
cmp -s "$PROBE/expected-knowledge.log" "$PROBE/knowledge.log" \
  || fail "knowledge-maintenance failure was not attempted exactly once: $(cat "$PROBE/knowledge.log")"
for task in business-accepted business-cancelled business-archived; do
  cmp -s "$PROBE/business-state-before/$task.json" "$PROBE/home/data/$task/task.json" \
    || fail "knowledge maintenance or reconciliation changed persisted business state for $task"
done
jq -e '.state == "done" and .progress.current_state == "accepted" and .progress.remaining_gap == ""' \
  "$PROBE/home/data/business-accepted/task.json" >/dev/null \
  || fail 'the accepted business fixture no longer has its actual accepted terminal state'
jq -e '.state == "archived" and .progress.current_state == "cancelled" and .progress.remaining_gap == ""' \
  "$PROBE/home/data/business-cancelled/task.json" >/dev/null \
  || fail 'the cancelled business fixture no longer has its actual cancelled terminal state'
jq -e '.state == "archived" and .progress.current_state == "archived incomplete" and .progress.remaining_gap == "artifact completeness remains unverified"' \
  "$PROBE/home/data/business-archived/task.json" >/dev/null \
  || fail 'the archived business fixture lost its actual terminal state or remaining gap'

for report in "$CODEX_REPORT" "$TRAE_REPORT"; do
  grep -Fq "$success_candidate_before_change" "$report" \
    || fail "$report did not consume the candidate captured by the earlier task"
  grep -Fq "v$success_version_after_change" "$report" \
    || fail "$report did not consume the captured candidate's current version"
  grep -Fq "$captured_receipt" "$report" \
    || fail "$report did not read the captured candidate's original source receipt"
  grep -Fqx 'CAPTURED_CANDIDATE_CONSUMPTION=adopted' "$report" \
    || fail "$report did not record adoption of the captured candidate"
  grep -Fqx 'CAPTURED_CANDIDATE_ACTION=terminal-success-and-artifact-ready-observed' "$report" \
    || fail "$report did not connect the captured candidate to observable use"
  grep -Fqx 'UNKNOWN_CARRIER_COUNTEREXAMPLE=refused-no-provider-action' "$report" \
    || fail "$report did not reject the captured candidate when carrier applicability was unknown"
done

for report in "$PI_REPORT" "$CODEX_REPORT" "$TRAE_REPORT"; do
  for receipt in source-z-valid-741 source-no-identity-852 source-same-entity-963 \
    source-duplicate-276 \
    source-conflict-a-417 source-conflict-b-628 source-revoked-539 source-unverified-184 \
    source-revoked-page-01-539 source-revoked-page-02-539 \
    source-revoked-page-03-539 source-revoked-page-04-539 \
    source-revoked-page-05-539 source-revoked-page-06-539 \
    source-revoked-page-07-539 source-revoked-page-08-539; do
    grep -Fq "$receipt" "$report" \
      || fail "$report did not prove an original source read for $receipt"
  done
  grep -Fq 'async-current-identity-readback' "$report" \
    || fail "$report omitted the applicable second-page mechanism candidate"
  for decision in adopted rejected revoked pending unknown; do
    grep -Eqi "$decision" "$report" \
      || fail "$report omitted the required $decision retrieval disposition"
  done
  grep -Fq 'fixture-evidence/conflict-a/report.md' "$report" \
    || fail "$report dropped conflict source A"
  grep -Fq 'fixture-evidence/conflict-b/report.md' "$report" \
    || fail "$report dropped conflict source B"
  grep -Fq 'fixture-snow-copy' "$report" \
    || fail "$report omitted the bounded no-history lookup"
  grep -Fq 'unknown' "$report" || fail "$report did not qualify missing history as unknown"
  for marker in SAME_CONDITION_DUPLICATE=referenced-existing \
    DIFFERENT_CONDITION=kept-separate REVOKED_RECOMMENDATION=refused; do
    grep -Fqx "$marker" "$report" || fail "$report omitted dedupe or refusal marker $marker"
  done
  case "$report" in
    "$PI_REPORT") identity_prefix=current-pi ;;
    "$CODEX_REPORT") identity_prefix=current-codex ;;
    *) identity_prefix=current-traex ;;
  esac
  grep -Fq "$identity_prefix-permission-mismatch-q" "$report" \
    || fail "$report omitted the present-identity permission counterexample"
  grep -Fq "$identity_prefix-region-mismatch-q" "$report" \
    || fail "$report omitted the present-identity region counterexample"
  grep -Fqx 'NO_IDENTITY_COUNTEREXAMPLE=refused-no-provider-action' "$report" \
    || fail "$report did not accept the independent no-identity refusal goal"
  grep -Fqx 'PERMISSION_COUNTEREXAMPLE=refused-no-provider-action' "$report" \
    || fail "$report did not accept the independent permission refusal goal"
  grep -Fqx 'REGION_COUNTEREXAMPLE=refused-no-provider-action' "$report" \
    || fail "$report did not accept the independent region refusal goal"
  ! grep -Eq '^  report: /tmp/|^  report: /data00/home/.*/\.treehouse/' "$report" \
    || fail "$report stored a transient absolute candidate provenance path"
done

printf 'status\tcurrent-pi-q\t\nstatus\tcurrent-codex-q\t\nstatus\tcurrent-traex-q\t\n' > "$PROBE/expected-provider.log"
cmp -s "$PROBE/expected-provider.log" "$PROBE/provider.log" \
  || fail "provider log was not exactly the three authorized current-identity reads: $(cat "$PROBE/provider.log")"

for wt in "$PI_WT" "$CODEX_WT" "$TRAEX_WT"; do
  [ -z "$(git -C "$wt" status --porcelain)" ] \
    || fail "experience worker changed project files in $wt"
done

pass 'fresh Pi, Codex, and TraeX workers consumed original evidence while capture, closure, recovery, and failure handling preserved business state'
