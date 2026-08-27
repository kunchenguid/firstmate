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

reset_route_state() {
  rm -rf "$FM_STATE_OVERRIDE/routing"
}

reserve_route() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 class=$7 risk=$8 mode=$9
  shift 9
  "$ROUTE" reserve --task "$task" --generation "$generation" --profile "$profile" \
    --provider "$provider" --lane "$lane" --account "$account" --class "$class" \
    --risk "$risk" --mode "$mode" --now 1000 "$@"
}

test_canary_cap_is_atomic_and_duplicate_reserve_is_idempotent() {
  local job rc successes=0
  reset_route_state
  for job in 1 2 3 4; do
    reserve_route "task-$job" "gen-$job" "profile-$job" "provider-$job" "lane-$job" none decomposable low canary >"$LAB/reserve-$job.out" 2>&1 &
    eval "pid_$job=$!"
  done
  for job in 1 2 3 4; do
    set +e
    eval "wait \$pid_$job"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || successes=$((successes + 1))
  done
  [ "$successes" -eq 3 ] || fail "atomic canary cap admitted $successes workers"
  [ "$(find "$FM_STATE_OVERRIDE/routing/reservations" -type f -name '*.json' | wc -l)" -eq 3 ] || fail "canary cap persisted the wrong active total"

  reset_route_state
  reserve_route task-1 gen-1 profile-1 provider-1 lane-1 none standard low automatic >/dev/null || fail "initial reservation failed"
  reserve_route task-1 gen-1 profile-1 provider-1 lane-1 none standard low automatic >/dev/null || fail "duplicate reservation was not idempotent"
  [ "$(find "$FM_STATE_OVERRIDE/routing/reservations" -type f -name '*.json' | wc -l)" -eq 1 ] || fail "duplicate reservation changed capacity"
  expect_failure_contains 'reservation-conflict' reserve_route task-1 gen-2 profile-1 provider-1 lane-1 none standard low automatic
  pass "canary admission is atomic and route generations are idempotent"
}

test_lane_account_and_burst_caps_are_enforced() {
  reset_route_state
  reserve_route task-1 gen-1 profile-1 xai pi-xai-1 none standard low automatic >/dev/null
  reserve_route task-2 gen-2 profile-2 xai pi-xai-1 none standard low automatic >/dev/null
  expect_failure_contains 'lane-cap:2' reserve_route task-3 gen-3 profile-3 xai pi-xai-1 none standard low automatic

  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-lane-1 codex-primary standard low automatic >/dev/null
  reserve_route task-2 gen-2 profile-2 openai codex-lane-2 codex-primary standard low automatic >/dev/null
  expect_failure_contains 'account-cap:2' reserve_route task-3 gen-3 profile-3 openai codex-lane-3 codex-primary standard low automatic

  reset_route_state
  for job in 1 2 3 4 5 6; do
    reserve_route "task-$job" "gen-$job" "profile-$job" "provider-$job" "lane-$job" none decomposable low automatic >/dev/null
  done
  expect_failure_contains 'global-cap:6' reserve_route task-7 gen-7 profile-7 provider-7 lane-7 none decomposable low automatic
  reserve_route task-7 gen-7 profile-7 provider-7 lane-7 none decomposable low automatic --burst >/dev/null || fail "qualified burst did not extend the automatic cap"
  expect_failure_contains 'burst-requires-decomposable-low-risk' reserve_route task-8 gen-8 profile-8 provider-8 lane-8 none standard low automatic --burst
  pass "lane, account, automatic, and burst caps are bounded"
}

test_reservation_verification_and_generation_release_are_exact() {
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary high_risk high automatic >/dev/null
  "$ROUTE" verify-reservation --task task-1 --generation gen-1 --profile profile-1 --provider openai --lane codex-primary --account codex-primary --class high_risk --risk high --mode automatic >/dev/null \
    || fail "exact reservation did not verify"
  expect_failure_contains 'reservation-mismatch' "$ROUTE" verify-reservation --task task-1 --generation gen-1 --profile wrong --provider openai --lane codex-primary --account codex-primary --class high_risk --risk high --mode automatic
  expect_failure_contains 'reservation-generation-mismatch' "$ROUTE" release --task task-1 --generation wrong
  [ -f "$FM_STATE_OVERRIDE/routing/reservations/task-1.json" ] || fail "wrong generation released a live reservation"
  "$ROUTE" release --task task-1 --generation gen-1 >/dev/null || fail "reservation release failed"
  "$ROUTE" release --task task-1 --generation gen-1 >/dev/null || fail "duplicate release was not idempotent"
  pass "reservation verification and release bind the complete route generation"
}

test_failure_policy_and_circuit_breaker_are_bounded() {
  local out
  reset_route_state
  out=$("$ROUTE" failure --task transient-1 --generation gen-1 --provider xai --lane pi-xai-1 --kind transient --now 1000) || fail "first transient failure failed"
  jq -e '.action == "retry"' <<<"$out" >/dev/null || fail "first transient failure did not return retry"
  out=$("$ROUTE" failure --task transient-1 --generation gen-2 --provider xai --lane pi-xai-1 --kind transient --now 1001) || fail "second transient failure failed"
  jq -e '.action == "fallback"' <<<"$out" >/dev/null || fail "second transient failure did not return fallback"
  "$ROUTE" failure --task quota-fallback --generation gen-1 --provider google --lane pi-google-1 --kind quota --now 1000 | jq -e '.action == "fallback"' >/dev/null \
    || fail "quota failure did not fall back"
  "$ROUTE" failure --task quota-1 --generation gen-1 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100 >/dev/null
  "$ROUTE" failure --task quota-2 --generation gen-2 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100 >/dev/null
  out=$("$ROUTE" failure --task quota-3 --generation gen-3 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100) || fail "third lane failure failed"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "third recent failure did not open a thirty-minute circuit"
  out=$("$ROUTE" failure --task quota-3 --generation gen-3 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1100) || fail "duplicate failure was not idempotent"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "duplicate failure changed the circuit"
  out=$("$ROUTE" failure --task quota-4 --generation gen-4 --provider moonshot --lane pi-moonshot-1 --kind quota --now 1200) || fail "open circuit failure check failed"
  jq -e '.action == "circuit-open" and .until == 2900' <<<"$out" >/dev/null || fail "failure during cooldown extended the circuit"
  expect_failure_contains 'circuit-open' reserve_route blocked gen-1 profile-x moonshot pi-moonshot-1 none standard low automatic
  "$ROUTE" reserve --task recovered --generation gen-1 --profile profile-x --provider moonshot --lane pi-moonshot-1 --account none --class standard --risk low --mode automatic --now 2901 >/dev/null \
    || fail "cooled-down circuit did not admit new work"
  "$ROUTE" failure --task unsafe --generation gen-1 --provider zai --lane pi-zai-1 --kind unsafe --now 1000 | jq -e '.action == "escalate"' >/dev/null \
    || fail "unsafe failure did not escalate"
  pass "failure actions retry once, open deterministic circuits, and escalate unsafe work"
}

test_score_finalize_and_outcome_privacy_are_strict() {
  local outcome
  reset_route_state
  reserve_route task-1 gen-1 profile-1 openai codex-primary codex-primary standard medium automatic >/dev/null
  expect_failure_contains 'forbidden outcome field: prompt' "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 --extra-json '{"prompt":"secret"}'
  expect_failure_contains 'unexpected outcome field: harmless' "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 --extra-json '{"harmless":true}'
  "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1010 >/dev/null || fail "score failed"
  "$ROUTE" score --task task-1 --generation gen-1 --terminal completed --tests pass --review pass --redundant no --now 1011 >/dev/null || fail "duplicate score was not idempotent"
  [ ! -e "$FM_STATE_OVERRIDE/routing/outcomes.jsonl" ] || fail "score finalized before safe cleanup"
  "$ROUTE" finalize --task task-1 --generation gen-1 --terminal completed >/dev/null || fail "finalize failed"
  "$ROUTE" finalize --task task-1 --generation gen-1 --terminal completed >/dev/null || fail "duplicate finalize was not idempotent"
  [ ! -e "$FM_STATE_OVERRIDE/routing/reservations/task-1.json" ] || fail "finalize leaked active capacity"
  [ "$(wc -l < "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")" -eq 1 ] || fail "finalize duplicated the outcome"
  outcome=$(cat "$FM_STATE_OVERRIDE/routing/outcomes.jsonl")
  jq -e 'keys == ["account","elapsedSeconds","generation","kind","lane","mode","profile","provider","redundant","review","risk","taskClass","taskId","terminal","tests","timestamp"] and .elapsedSeconds == 10' <<<"$outcome" >/dev/null \
    || fail "outcome schema was not bounded"
  ! grep -qiE 'prompt|source|secret|token|cookie|authorization|password' "$FM_STATE_OVERRIDE/routing/outcomes.jsonl" \
    || fail "private payload marker reached the outcome ledger"
  pass "score and finalization are idempotent and privacy-safe"
}

test_observation_evidence_status_and_report_are_non_mutating() {
  local decision status report
  reset_route_state
  write_request standard implementation low false 1 strong 120
  write_candidates "[$(candidate observed lane-1 3 1 0 0 0 null)]"
  decision=$(select_json) || fail "simulation decision failed"
  printf '%s\n' "$decision" >"$LAB/decision.json"
  "$ROUTE" observe --request "$REQUEST" --decision "$LAB/decision.json" --now 1000 >/dev/null || fail "simulation observation failed"
  [ ! -d "$FM_STATE_OVERRIDE/routing/reservations" ] || [ -z "$(find "$FM_STATE_OVERRIDE/routing/reservations" -type f -name '*.json' -print -quit)" ] \
    || fail "simulation observation created active capacity"
  "$ROUTE" evidence --work-type implementation | jq -e '. == [{"profile":"observed","successes":0,"attempts":1}]' >/dev/null \
    || fail "evidence did not expose raw counts only"

  reserve_route live gen-live active openai codex-primary codex-primary standard low automatic >/dev/null
  status=$("$ROUTE" status) || fail "routing status failed"
  jq -e '.caps == {"canary":3,"automatic":6,"burst":8,"perLane":2} and .active.total == 1 and .openCircuits == []' <<<"$status" >/dev/null \
    || fail "status omitted caps or active totals"

  "$ROUTE" release --task live --generation gen-live >/dev/null
  report=$("$ROUTE" report --stage simulation --minimum 1) || fail "simulation report failed"
  jq -e '.stage == "simulation" and .minimum == 1 and .count == 1 and .meetsMinimum == true and .medianElapsedSeconds == 120' <<<"$report" >/dev/null \
    || fail "simulation report gates or median were not deterministic"
  pass "observations do not reserve capacity and reports expose bounded aggregate facts"
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
test_canary_cap_is_atomic_and_duplicate_reserve_is_idempotent
test_lane_account_and_burst_caps_are_enforced
test_reservation_verification_and_generation_release_are_exact
test_failure_policy_and_circuit_breaker_are_bounded
test_score_finalize_and_outcome_privacy_are_strict
test_observation_evidence_status_and_report_are_non_mutating
