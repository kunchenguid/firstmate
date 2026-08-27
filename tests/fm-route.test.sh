#!/usr/bin/env bash
# Behavioral coverage for the pure subscription-routing selector.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-route-tests)
ROUTE="$ROOT/bin/fm-route.sh"
REQUEST="$LAB/request.json"
CANDIDATES="$LAB/candidates.json"
export FM_STATE_OVERRIDE="$LAB/state"

command -v jq >/dev/null 2>&1 || fail "jq is required for routing tests"

write_request() {
  jq -n \
    --arg task_id task-1 \
    --arg task_class "$1" \
    --arg work_type "$2" \
    --arg risk "$3" \
    --argjson independent "$4" \
    --argjson requested_workers "$5" \
    --arg reasoning "$6" \
    --argjson estimated_seconds "$7" \
    '{taskId:$task_id,taskClass:$task_class,workType:$work_type,risk:$risk,independent:$independent,requestedWorkers:$requested_workers,requiredReasoningClass:$reasoning,estimatedSeconds:$estimated_seconds}' \
    >"$REQUEST"
}

write_candidates() {
  printf '%s\n' "$1" >"$CANDIDATES"
}

candidate() {
  jq -cn \
    --arg profile "$1" \
    --arg lane "$2" \
    --argjson fit "$3" \
    --argjson spend "$4" \
    --argjson active "$5" \
    --argjson successes "$6" \
    --argjson attempts "$7" \
    --argjson cost "$8" \
    '{profile:$profile,harness:"pi",model:("model-"+$profile),provider:"provider",lane:$lane,account:"none",fitTier:$fit,reasoningClass:"strong",catalogSupported:true,authState:"usable",spendPriority:$spend,runwaySeconds:10000,activeLane:$active,historySuccesses:$successes,historyAttempts:$attempts,costTier:$cost}'
}

write_candidate_array() {
  printf '%s\n' "$@" | jq -s . >"$CANDIDATES"
}

select_json() {
  "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" --now 1000
}

expect_failure_contains() {
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected command failure: $*"
  assert_contains "$out" "$expected" "routing validation error"
}

test_fit_beats_quota() {
  write_request standard implementation medium false 1 strong 7200
  write_candidate_array \
    "$(candidate codex-sol codex-primary 3 -1 99 0 0 null)" \
    "$(candidate pi-flash pi-google-1 2 4 0 0 0 null)"
  select_json | jq -e '
    keys == ["action","maxWorkers","ranked","reason","rejected","selected","uncertainty"]
    and .selected.profile == "codex-sol"
    and .reason == "lexicographic-policy"
  ' >/dev/null \
    || fail "task fit did not outrank quota and load"
  pass "task fit is the first lexicographic selector key"
}

test_unknowns_are_disclosed_not_zero() {
  write_request standard implementation low false 1 standard 3600
  write_candidates '[{"profile":"pi-kimi","harness":"pi","model":"cliproxyapi/kimi-k3","provider":"moonshot","lane":"pi-moonshot-1","account":"none","fitTier":3,"reasoningClass":"strong","catalogSupported":true,"authState":null,"spendPriority":null,"runwaySeconds":null,"activeLane":0,"historySuccesses":0,"historyAttempts":0,"costTier":null}]'
  select_json | jq -e '
    .selected.profile == "pi-kimi"
    and (.uncertainty | index("pi-kimi:auth,quota,runway,cost"))
    and .selected.authState == null
    and .selected.spendPriority == null
    and .selected.runwaySeconds == null
    and .selected.costTier == null
  ' >/dev/null || fail "unknown evidence was treated as zero or omitted"
  pass "null auth, quota, runway, and cost stay eligible and disclosed"
}

test_worker_budget_is_bounded() {
  local row out task_class independent requested expected
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  for row in \
    'trivial false 4 1' \
    'standard false 3 1' \
    'decomposable true 7 4' \
    'decomposable true 2 2' \
    'decomposable false 4 1' \
    'ambiguous true 5 2' \
    'high_risk true 8 2'; do
    read -r task_class independent requested expected <<<"$row"
    write_request "$task_class" implementation medium "$independent" "$requested" strong 3600
    out=$(select_json) || fail "worker budget case failed: $row"
    [ "$(jq -r '.maxWorkers' <<<"$out")" = "$expected" ] || fail "worker budget case $row returned $(jq -r '.maxWorkers' <<<"$out")"
  done
  pass "task worker budgets honor class, independence, request, and hard cap"
}

test_every_decision_has_the_complete_output_shape() {
  local out
  write_request standard implementation medium false 1 maximum 3600
  write_candidates "[$(candidate weak lane-1 3 1 0 0 0 null)]"
  out=$(select_json) || fail "no-qualified decision failed"
  jq -e '
    keys == ["action","maxWorkers","ranked","reason","rejected","selected","uncertainty"]
    and .action == "escalate"
    and .reason == "no-qualified-profile"
    and .selected == null
    and (.ranked | type) == "array"
    and (.rejected | type) == "array"
    and (.uncertainty | type) == "array"
    and .maxWorkers == 1
  ' <<<"$out" >/dev/null || fail "escalation omitted required output fields"
  pass "selected and escalated decisions share one complete output schema"
}

test_rejections_account_for_every_ineligible_candidate() {
  local catalog auth reasoning runway out
  write_request standard implementation medium false 1 strong 5000
  catalog=$(candidate catalog lane-a 3 1 0 0 0 null | jq '.catalogSupported=false')
  auth=$(candidate auth lane-b 3 1 0 0 0 null | jq '.authState="unusable"')
  reasoning=$(candidate reasoning lane-c 3 1 0 0 0 null | jq '.reasoningClass="standard"')
  runway=$(candidate runway lane-d 3 1 0 0 0 null | jq '.runwaySeconds=4999')
  write_candidate_array "$catalog" "$auth" "$reasoning" "$runway"
  out=$(select_json) || fail "rejection accounting decision failed"
  jq -e '
    .action == "escalate"
    and (.rejected | length) == 4
    and (.rejected[] | select(.profile == "catalog") | .reasons == ["catalog-unsupported"])
    and (.rejected[] | select(.profile == "auth") | .reasons == ["auth-unusable"])
    and (.rejected[] | select(.profile == "reasoning") | .reasons == ["reasoning-insufficient"])
    and (.rejected[] | select(.profile == "runway") | .reasons == ["runway-insufficient"])
  ' <<<"$out" >/dev/null || fail "ineligible candidates were not fully accounted for"
  pass "rejected candidates carry explicit eligibility reasons"
}

test_load_precedes_history() {
  write_request standard implementation medium false 1 strong 3600
  write_candidate_array \
    "$(candidate idle lane-idle 3 1 50 0 0 null)" \
    "$(candidate busy lane-busy 3 1 0 100 100 null)"
  mkdir -p "$FM_STATE_OVERRIDE/routing/reservations"
  printf '%s\n' '{"taskId":"other","lane":"lane-busy"}' >"$FM_STATE_OVERRIDE/routing/reservations/other.json"
  select_json | jq -e '.selected.profile == "idle" and .selected.activeLane == 0' >/dev/null \
    || fail "current lane load did not precede caller history"
  pass "selector overwrites caller load and applies it before history"
}

test_history_is_read_from_state_only_for_equal_attempts() {
  local out
  rm -rf "$FM_STATE_OVERRIDE/routing"
  mkdir -p "$FM_STATE_OVERRIDE/routing"
  write_request standard implementation medium false 1 strong 3600
  write_candidate_array \
    "$(candidate proven lane-a 3 1 88 0 99 null)" \
    "$(candidate weak lane-b 3 1 88 99 99 null)"
  printf '%s\n' \
    '{"profile":"proven","workType":"implementation","terminal":"completed"}' \
    '{"profile":"proven","workType":"implementation","terminal":"completed"}' \
    '{"profile":"weak","workType":"implementation","terminal":"completed"}' \
    '{"profile":"weak","workType":"implementation","terminal":"failed_safe"}' \
    >"$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  out=$(select_json) || fail "history-backed selection failed"
  jq -e '.selected.profile == "proven" and .selected.historySuccesses == 2 and .selected.historyAttempts == 2' <<<"$out" >/dev/null \
    || fail "caller history was not replaced with equal-attempt routing history"

  printf '%s\n' '{"profile":"weak","workType":"implementation","terminal":"failed_safe"}' >>"$FM_STATE_OVERRIDE/routing/outcomes.jsonl"
  out=$(select_json) || fail "unequal-attempt decision failed"
  jq -e '.action == "escalate" and .reason == "evidence-tie" and .selected == null' <<<"$out" >/dev/null \
    || fail "raw successes were compared across unequal attempt counts"
  pass "raw history breaks ties only when attempt counts are equal"
}

test_cost_breaks_ties_only_when_every_cost_is_known() {
  local out
  rm -rf "$FM_STATE_OVERRIDE/routing"
  write_request standard implementation medium false 1 strong 3600
  write_candidate_array \
    "$(candidate unknown lane-a 3 1 0 0 0 null)" \
    "$(candidate known lane-b 3 1 0 0 0 1)"
  out=$(select_json) || fail "unknown-cost decision failed"
  jq -e '.action == "escalate" and .reason == "evidence-tie"' <<<"$out" >/dev/null \
    || fail "known cost was used when another finalist cost was unknown"

  write_candidate_array \
    "$(candidate expensive lane-a 3 1 0 0 0 3)" \
    "$(candidate cheap lane-b 3 1 0 0 0 1)"
  out=$(select_json) || fail "known-cost decision failed"
  jq -e '.selected.profile == "cheap"' <<<"$out" >/dev/null || fail "lower known cost did not break the final tie"
  pass "cost is a tie-break only when every finalist cost is known"
}

test_request_schema_is_strict() {
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  write_request standard implementation medium false 1 strong 3600
  jq 'del(.risk)' "$REQUEST" >"$REQUEST.next" && mv "$REQUEST.next" "$REQUEST"
  expect_failure_contains 'invalid request schema: missing risk' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_request standard implementation medium false 1 strong 3600
  jq '.unexpected=true' "$REQUEST" >"$REQUEST.next" && mv "$REQUEST.next" "$REQUEST"
  expect_failure_contains 'invalid request schema: unexpected field unexpected' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_request standard implementation medium false 0 strong 3600
  expect_failure_contains 'invalid request schema: requestedWorkers' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_request standard implementation medium false 9 strong 3600
  expect_failure_contains 'invalid request schema: requestedWorkers' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  pass "request validation requires exactly the typed routing contract"
}

test_candidate_schema_is_strict() {
  write_request standard implementation medium false 1 strong 3600
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq 'del(.provider)')]"
  expect_failure_contains 'invalid candidate schema: at index 0: missing provider' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq '.prompt="secret"')]"
  expect_failure_contains 'invalid candidate schema: at index 0: unexpected field prompt' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 2 1 null)]"
  expect_failure_contains 'invalid candidate schema: at index 0: historySuccesses' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq '.harness="opencode"')]"
  expect_failure_contains 'invalid candidate schema: at index 0: harness' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null | jq '.account="pi-secret-lane"')]"
  expect_failure_contains 'invalid candidate schema: at index 0: account' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"

  write_candidate_array \
    "$(candidate duplicate lane-1 3 1 0 0 0 null)" \
    "$(candidate duplicate lane-2 3 1 0 0 0 null)"
  expect_failure_contains 'invalid candidate schema: duplicate profile duplicate' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  pass "candidate validation requires exactly the typed routing contract"
}

test_input_and_now_validation_are_sanitized() {
  write_request standard implementation medium false 1 strong 3600
  printf '{bad json\n' >"$CANDIDATES"
  expect_failure_contains 'invalid candidates JSON' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES"
  write_candidates "[$(candidate only lane-1 3 1 0 0 0 null)]"
  expect_failure_contains 'invalid --now: expected non-negative epoch' "$ROUTE" select --request "$REQUEST" --candidates "$CANDIDATES" --now tomorrow
  pass "malformed input reports stable diagnostics without raw jq output"
}

test_fit_beats_quota
test_unknowns_are_disclosed_not_zero
test_worker_budget_is_bounded
test_every_decision_has_the_complete_output_shape
test_rejections_account_for_every_ineligible_candidate
test_load_precedes_history
test_history_is_read_from_state_only_for_equal_attempts
test_cost_breaks_ties_only_when_every_cost_is_known
test_request_schema_is_strict
test_candidate_schema_is_strict
test_input_and_now_validation_are_sanitized
