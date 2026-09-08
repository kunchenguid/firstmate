#!/usr/bin/env bash
# Lesson-admission filter for /stow over fm-model-telemetry.sh sheet fixtures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/.agents/skills/stow/SKILL.md"
SHEET_BIN="$ROOT/bin/fm-model-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-lesson-admission)
FIXTURES="$TMP_ROOT/fixtures.json"

candidates() {
  jq -r '
    .[] | select(
      (.stepReruns != null and .stepReruns > 0) or
      (.primaryFailureClass != null and .primaryFailureClass != "none")
    ) | .name
  ' "$FIXTURES"
}

make_fixtures() {
  jq -n '
    [
      {name:"rerun-without-defect", stepReruns:2, primaryFailureClass:"none", correctionCount:2},
      {name:"green-first-pass", stepReruns:0, primaryFailureClass:"none", correctionCount:0},
      {name:"step-reruns-absent", stepReruns:null, primaryFailureClass:null, correctionCount:0},
      {name:"correction-count-alone", stepReruns:null, primaryFailureClass:"none", correctionCount:3},
      {name:"unknown-failure-class", stepReruns:null, primaryFailureClass:"unknown", correctionCount:0}
    ]
  ' > "$FIXTURES"
}

rerun_intake_payload() {
  jq -cn '{attemptClass:"real",source:"firstmate",taskRootId:null,parentAttemptId:null,projectRef:"project_0123456789abcdef",taskClass:"bounded-implementation-proven-root-fix",tuple:{harness:"codex",provider:"openai",model:"gpt-5",effort:"high",modelVersion:"gpt-5",cliVersion:"codex-cli 1.2.3"},selection:{matchedRule:"rule-1",configSha256:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",fitReasons:["task-class"],candidateAssessments:[{tuple:{harness:"codex",provider:"openai",model:"gpt-5",effort:"high",modelVersion:"gpt-5",cliVersion:"codex-cli 1.2.3"},eligibility:"selected",reasons:["class-fit"]}],quota:{decision:"selected",headroom:"sufficient",runway:"sufficient",observedAt:"2026-08-02T00:00:00Z"}},neutralExecution:{correlation:null,capabilityProfile:"not-applicable",owner:"not-applicable",phase:null,behavioralResult:"not-applicable"},evaluation:{kind:"none",fixtureId:null,fixtureManifestSha256:null,oracleId:null,oracleSha256:null,sourceCommit:null},startedAt:"2026-08-02T00:00:00Z",privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"}}'
}

rerun_facts_payload() {
  jq -cn '{gate:{source:"no-mistakes",result:"green",stepReruns:2},outcomeLink:{kind:"commit",id:"0123456789abcdef"},usage:{inputTokens:null,outputTokens:null,cost:null,currency:null},wallSeconds:60}'
}

test_unknown_means_absent_or_null() {
  make_fixtures
  local got
  got=$(jq -r '
    .[] | select(
      .stepReruns == null and .primaryFailureClass == null
    ) | .name
  ' "$FIXTURES")
  [ "$got" = "step-reruns-absent" ] || fail "absent or null should be the only unknown: $got"
  pass "unknown means absent or null fields"
}

test_sheet_candidate_filter() {
  make_fixtures
  local got
  got=$(candidates | sort | paste -sd, -)
  [ "$got" = "rerun-without-defect,unknown-failure-class" ] \
    || fail "candidate filter expected rerun-without-defect and unknown-failure-class, got: $got"
  pass "sheet candidate filter separates candidates from non-candidates"
}

test_correction_count_alone_is_not_candidate() {
  make_fixtures
  local got
  got=$(candidates | grep -c '^correction-count-alone$' || true)
  [ "$got" -eq 0 ] || fail "correctionCount alone produced a candidate"
  pass "correctionCount alone is not a candidate"
}

test_skill_requires_evidence_for_admission() {
  assert_grep 'A candidate is not a lesson' "$SKILL" \
    "skill must keep candidate distinct from lesson"
  assert_grep 'instruction-shaped reusable fact' "$SKILL" \
    "skill must require a reusable fact for admission"
  assert_grep 'named regression or verification artifact' "$SKILL" \
    "skill must require a named artifact for admission"
  assert_grep 'oracle=fail' "$SKILL" \
    "skill must name oracle=fail as admission evidence"
  assert_grep 'distiller is never the actor' "$SKILL" \
    "skill must keep distiller separate from actor"
  pass "skill admission gate requires reusable fact and named evidence"
}

test_skill_edit_rules_present() {
  assert_grep 'Inspect-then-update the canonical owner' "$SKILL" \
    "skill must require inspect-then-update"
  assert_grep 'Archive superseded text to the cold tier' "$SKILL" \
    "skill must archive superseded text"
  assert_grep 'Never rewrite a whole file' "$SKILL" \
    "skill must forbid whole-file rewrites"
  assert_grep 'never append a duplicate' "$SKILL" \
    "skill must forbid duplicate appends"
  pass "skill edit rules are present"
}

test_skill_expiry_and_trigger_rules_present() {
  assert_grep 'perishable condition binds to the behavior and its verified oracle' "$SKILL" \
    "skill must bind perishable conditions to behavior and oracle"
  assert_grep 'M4 bug-bash regression pointers' "$SKILL" \
    "skill must name M4 bug-bash regression pointers as trigger"
  assert_grep 'owner or reviewer corrections' "$SKILL" \
    "skill must name owner/reviewer corrections as trigger"
  assert_grep 'ledger rows with explicit gate-evidence fail' "$SKILL" \
    "skill must name ledger gate-evidence fail as trigger"
  pass "skill expiry and trigger rules are present"
}

test_skill_invocation_remains_manual() {
  assert_grep 'turn-end guard calls' "$SKILL" \
    "skill must reference the turn-end guard"
  assert_grep 'fm-stow-cadence-lab.sh activity' "$SKILL" \
    "skill must say cadence lab records activity, not run"
  assert_grep 'do not add a scheduler' "$SKILL" \
    "skill must forbid adding a scheduler"
  pass "skill keeps /stow invocation manual"
}

test_skill_still_refuses_tracked_skill_writes() {
  assert_grep 'stow process never creates or writes a firstmate-repo-tracked skill' "$SKILL" \
    "skill must refuse tracked skill creation"
  assert_grep 'Changing firstmate' "$SKILL" \
    "skill must keep tracked skill changes as a deliberate repo task"
  pass "skill still refuses to write tracked skills"
}

test_telemetry_sheet_command_exists() {
  [ -x "$SHEET_BIN" ] || fail "fm-model-telemetry.sh is missing or not executable"
  "$SHEET_BIN" sheet --format json >/dev/null || fail "sheet command failed on empty ledger"
  pass "telemetry sheet command is the read surface"
}

test_skill_candidate_filter_matches_real_sheet() {
  local home sheet
  home="$TMP_ROOT/real-sheet/home"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$SHEET_BIN" intake --state "$home/state" --task stow-rerun \
    --payload "$(rerun_intake_payload)" >/dev/null || fail "rerun intake failed"
  FM_HOME="$home" "$SHEET_BIN" terminal-facts --state "$home/state" --task stow-rerun \
    --payload "$(rerun_facts_payload)" >/dev/null || fail "rerun terminal-facts failed"
  sheet=$(FM_HOME="$home" "$SHEET_BIN" sheet --format json) || fail "sheet failed on recorded rerun row"
  printf '%s' "$sheet" | jq -e '.[0].stepReruns == 2 and (.[0] | has("gateFacts") | not)' >/dev/null \
    || fail "real sheet does not expose stepReruns as a top-level column: $sheet"
  printf '%s' "$sheet" | jq -e '[.[] | select((.stepReruns != null and .stepReruns > 0) or (.primaryFailureClass != null and .primaryFailureClass != "none"))] | length == 1' >/dev/null \
    || fail "candidate filter over the real sheet missed the recorded rerun row"
  assert_no_grep 'gateFacts.stepReruns' "$SKILL" \
    "skill must not name gateFacts.stepReruns; the sheet flattens it to stepReruns"
  assert_grep "sheet's \`stepReruns\` column" "$SKILL" \
    "skill must name the sheet's stepReruns column in the candidate filter"
  pass "skill candidate filter matches the real sheet shape"
}

test_sheet_candidate_filter
test_unknown_means_absent_or_null
test_correction_count_alone_is_not_candidate
test_skill_requires_evidence_for_admission
test_skill_edit_rules_present
test_skill_expiry_and_trigger_rules_present
test_skill_invocation_remains_manual
test_skill_still_refuses_tracked_skill_writes
test_telemetry_sheet_command_exists
test_skill_candidate_filter_matches_real_sheet
