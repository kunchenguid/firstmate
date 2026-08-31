#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAILY="$ROOT/bin/fm-daily.sh"
TMP_ROOT=$(fm_test_tmproot fm-daily)

make_fixture() {
  local name=$1 fixture_root home
  fixture_root="$TMP_ROOT/$name/root"
  home="$TMP_ROOT/$name/home"
  mkdir -p "$fixture_root/bin" "$home/config" "$home/data" "$home/state"
  cat > "$fixture_root/bin/fm-model-telemetry.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_TELEMETRY_FAIL:-0}" = 1 ]; then
  printf 'error: model telemetry: malformed ledger row 2\n' >&2
  exit 1
fi
printf '%s\n' "${FM_TEST_LEDGER_JSON:-[]}"
SH
  chmod +x "$fixture_root/bin/fm-model-telemetry.sh"
  printf '%s\n%s\n' "$fixture_root" "$home"
}

ledger_row() {
  local classification=$1 failure=$2 started=$3 ended=$4 harness=$5 model=$6 effort=$7 wall=$8
  jq -cn \
    --arg classification "$classification" \
    --arg failure "$failure" \
    --arg started "$started" \
    --arg ended "$ended" \
    --arg harness "$harness" \
    --arg model "$model" \
    --arg effort "$effort" \
    --argjson wall "$wall" \
    '{recordType:"attempt",schemaVersion:"firstmate.model-run-telemetry/v1",attemptId:"mra_00000000-0000-4000-8000-000000000001",taskRootId:"mrt_00000000-0000-4000-8000-000000000001",parentAttemptId:null,source:"firstmate",attemptClass:"real",projectRef:"project_0123456789abcdef",taskClass:"bounded-implementation-proven-root-fix",harness:$harness,provider:"test-provider",model:$model,effort:$effort,exploration:null,machineLoadAverage1m:null,machineLogicalCpuCount:null,state:"terminal",classification:$classification,quality:$classification,stepReruns:null,gateSource:null,primaryFailureClass:$failure,startedAt:$started,endedAt:(if $ended=="" then null else $ended end),wallSeconds:$wall,costReported:false,cost:null,currency:null,costPerAcceptedDelivery:null,legacyRaw:null}'
}

legacy_row() {
  local day=$1 outcome=$2
  jq -cn --arg day "$day" --arg outcome "$outcome" \
    '{recordType:"legacy",legacyRaw:{date:$day,outcome:$outcome}}'
}

test_invalid_date_is_refused() {
  local err rc
  set +e
  err=$("$DAILY" 2026-02-30 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid calendar date succeeded"
  assert_contains "$err" "invalid date: 2026-02-30" "invalid date diagnostic"
  pass "daily report refuses malformed calendar dates"
}

test_help_describes_manual_contract() {
  local out
  out=$("$DAILY" --help) || fail "daily report help failed"
  assert_contains "$out" "Usage:" "help usage"
  assert_contains "$out" "tasks-axi" "tasks-axi dependency"
  assert_contains "$out" "Legacy" "legacy gap contract"
  assert_contains "$out" "Unmatched status lines" "status skip contract"
  pass "daily report help documents its manual and honest-gap contract"
}

test_reports_dated_deliveries_and_terminal_outcomes() {
  local paths fixture_root home ledger out
  paths=$(make_fixture dated)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-a - Active work (repo: alpha) (kind: ship)

## Queued

## Done
- [x] delivered-a - Delivered change (repo: alpha) (kind: ship) (merged 2026-08-02)
- [x] prior-a - Prior change (repo: alpha) (kind: ship) (done 2026-08-01)
- [x] undated-a - Undated change (repo: alpha) (kind: ship)
EOF
  : > "$home/data/routing-outcomes.jsonl"
  printf 'working [key=delivery] [corr=abc123]: undated event\nfailed: undated failure\n' > "$home/state/active-a.status"
  ledger=$(jq -cn \
    --argjson accepted "$(ledger_row accepted none 2026-08-02T12:00:00Z 2026-08-02T12:01:00Z codex gpt-5.6-sol high 60)" \
    --argjson failed "$(ledger_row failed tool 2026-08-02T13:00:00Z 2026-08-02T13:02:00Z claude opus xhigh 120)" \
    --argjson incomplete "$(ledger_row incomplete unknown 2026-08-02T14:00:00Z '' grok grok-4 medium null)" \
    '[$accepted,$failed,$incomplete]')

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON="$ledger" "$DAILY" 2026-08-02) \
    || fail "dated daily report failed"

  assert_contains "$out" "Daily report - 2026-08-02" "dated report heading"
  assert_contains "$out" "At a glance: at least 1 deliveries; at least 1 failed attempts; active blockers unavailable." \
    "partial evidence summary floors"
  assert_contains "$out" "1. What did we deliver?" "delivery question"
  assert_contains "$out" "delivered-a [alpha/ship]: Delivered change" "dated delivery"
  assert_not_contains "$out" "prior-a" "prior delivery excluded"
  assert_contains "$out" "2. What went wrong?" "failure question"
  assert_contains "$out" "tool - claude/opus/xhigh - 120s" "explicit failure outcome"
  assert_contains "$out" "1 attempt lacks an explicit terminal outcome" "incomplete outcome limitation"
  assert_contains "$out" "3. What is blocking?" "blocking question"
  assert_contains "$out" "Cannot answer for a past day" "historical blocker limitation"
  assert_contains "$out" "4. What is good - what should we keep doing?" "positive question"
  assert_contains "$out" "accepted - codex/gpt-5.6-sol/high - 60s" "explicit accepted outcome"
  assert_contains "$out" "status lines have no timestamps" "status attribution limitation"
  pass "daily report separates dated facts from missing terminal and status evidence"
}

test_legacy_only_day_reports_named_gap() {
  local paths fixture_root home ledger out
  paths=$(make_fixture legacy)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  : > "$home/data/routing-outcomes.jsonl"
  ledger=$(jq -cn --argjson row "$(legacy_row 2026-07-30 success)" '[$row]')

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON="$ledger" "$DAILY" 2026-07-30) \
    || fail "legacy-only daily report failed"

  assert_contains "$out" "1 legacy ledger row for 2026-07-30 cannot be classified" "legacy named gap"
  assert_contains "$out" "failed attempts unavailable" "legacy outcome summary gap"
  pass "daily report names legacy-only activity instead of reporting a false zero"
}

test_undated_done_task_reports_named_gap() {
  local paths fixture_root home out section
  paths=$(make_fixture undated-done)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] undated-ship - Undated delivery (repo: alpha) (kind: ship)
EOF
  : > "$home/data/routing-outcomes.jsonl"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY" 2026-08-02) \
    || fail "undated-done daily report failed"
  section=$(printf '%s\n' "$out" | sed -n '/^1\. What did we deliver?$/,/^2\. What went wrong?$/p')

  assert_contains "$section" "1 completed task has no close date" "undated delivery gap"
  assert_not_contains "$section" "No activity recorded" "undated delivery false zero"
  assert_contains "$out" "At a glance: deliveries unavailable" "undated delivery summary gap"
  pass "daily report names undated completed work instead of reporting a false zero"
}

test_data_and_state_overrides_select_active_home_sources() {
  local paths fixture_root home override_data override_state out
  paths=$(make_fixture overrides)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  override_data="$TMP_ROOT/overrides/data"
  override_state="$TMP_ROOT/overrides/state"
  mkdir -p "$override_data" "$override_state"
  cat > "$override_data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] override-ship - Override delivery (repo: alpha) (kind: ship) (done 2026-08-02)
EOF
  : > "$override_data/routing-outcomes.jsonl"
  printf 'working [key=override] [corr=xyz]: undated event\n' > "$override_state/override.status"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_DATA_OVERRIDE="$override_data" \
    FM_STATE_OVERRIDE="$override_state" FM_TEST_LEDGER_JSON='[]' "$DAILY" 2026-08-02) \
    || fail "override daily report failed"

  assert_contains "$out" "override-ship [alpha/ship]: Override delivery" "override backlog"
  assert_contains "$out" "1 status log(s) present" "override state"
  pass "daily report reads data and state from the active home overrides"
}

test_manual_backend_is_a_named_gap() {
  local paths fixture_root home out
  paths=$(make_fixture manual-backend)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  : > "$home/data/routing-outcomes.jsonl"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY" 2026-08-02) \
    || fail "manual-backend daily report failed"

  assert_contains "$out" "Data gap: tasks-axi backlog backend is disabled or incompatible" "backend owner gap"
  pass "daily report honors the tasks-axi backend owner"
}

test_captain_threads_are_not_deliveries() {
  local paths fixture_root home out section
  paths=$(make_fixture captain-kind)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] shipped-a - Product change (repo: alpha) (kind: ship) (done 2026-08-02)
- [x] decision-a - Answer a question (repo: alpha) (kind: captain) (done 2026-08-02)
EOF
  : > "$home/data/routing-outcomes.jsonl"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY" 2026-08-02) \
    || fail "captain-kind daily report failed"
  section=$(printf '%s\n' "$out" | sed -n '/^1\. What did we deliver?$/,/^2\. What went wrong?$/p')

  assert_contains "$section" "shipped-a" "ship delivery"
  assert_not_contains "$section" "decision-a" "captain bookkeeping excluded"
  pass "daily report excludes captain decision threads from deliveries"
}

test_compact_output_caps_details_and_full_expands_them() {
  local paths fixture_root home compact full
  paths=$(make_fixture capped)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] shipped-1 - Product change 1 (repo: alpha) (kind: ship) (done 2026-08-02)
- [x] shipped-2 - Product change 2 (repo: alpha) (kind: ship) (done 2026-08-02)
- [x] shipped-3 - Product change 3 (repo: alpha) (kind: ship) (done 2026-08-02)
- [x] shipped-4 - Product change 4 (repo: alpha) (kind: ship) (done 2026-08-02)
- [x] shipped-5 - Product change 5 (repo: alpha) (kind: ship) (done 2026-08-02)
EOF
  : > "$home/data/routing-outcomes.jsonl"

  compact=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY" 2026-08-02) \
    || fail "compact daily report failed"
  full=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY" --full 2026-08-02) \
    || fail "full daily report failed"

  assert_contains "$compact" "... 2 more deliveries (run with --full)." "compact collapse"
  assert_not_contains "$compact" "shipped-5" "compact detail cap"
  assert_contains "$full" "shipped-5" "full detail"
  assert_not_contains "$full" "more deliveries" "full has no collapse"
  pass "daily report caps compact detail and expands it only on request"
}

test_unclassified_attempts_keep_both_refusals() {
  local paths fixture_root home ledger out count
  paths=$(make_fixture refusal)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  : > "$home/data/routing-outcomes.jsonl"
  ledger=$(jq -cn \
    --argjson first "$(ledger_row incomplete unknown 2026-08-02T12:00:00Z '' codex gpt-5.6-sol high null)" \
    --argjson second "$(ledger_row incomplete unknown 2026-08-02T13:00:00Z '' claude opus xhigh null)" \
    '[$first,$second]')

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON="$ledger" "$DAILY" 2026-08-02) \
    || fail "unclassified daily report failed"
  count=$(printf '%s\n' "$out" | grep -c 'Cannot answer: 2 attempts lacks an explicit terminal outcome')

  [ "$count" -eq 2 ] || fail "both honest refusals were not preserved: $out"
  assert_contains "$out" "failed attempts unavailable" "unclassified outcome summary gap"
  pass "daily report keeps both explicit-outcome refusals"
}

test_default_today_reports_live_blockers() {
  local paths fixture_root home out today
  paths=$(make_fixture blockers)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  today=$(date +%F)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] prerequisite-a - Prerequisite work (repo: alpha) (kind: ship)
- [ ] prerequisite-b - Second prerequisite (repo: alpha) (kind: ship)

## Queued
- [ ] blocked-a - Waiting delivery (repo: beta) (kind: ship) blocked-by: prerequisite-a - dependency not merged
- [ ] blocked-multi - Multi dependency work blocked-by: prerequisite-a blocked-by: prerequisite-b (repo: delta) (kind: ship)
- [ ] held-multi - Parked multi dependency blocked-by: prerequisite-a blocked-by: prerequisite-b (repo: gamma) (kind: scout) (hold: captain decision pending) (hold-kind: captain)

## Done
EOF
  : > "$home/data/routing-outcomes.jsonl"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY") \
    || fail "default daily report failed"

  assert_contains "$out" "Daily report - $today" "default date"
  assert_contains "$out" "At a glance: 0 deliveries; 0 failed attempts; 2 active blockers." \
    "only active blocker count"
  assert_contains "$out" "blocked-a [beta/ship]: Waiting delivery - blocked by 1 task" \
    "single dependency blocker"
  assert_contains "$out" "blocked-multi [delta/ship]: Multi dependency work - blocked by 2 tasks" \
    "multi dependency blocker"
  assert_not_contains "$out" "held-multi" "dependency-blocked parked hold excluded"
  pass "daily report defaults to today and reports only active blockers"
}

test_present_empty_sources_report_no_activity() {
  local paths fixture_root home out count
  paths=$(make_fixture empty)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  : > "$home/data/routing-outcomes.jsonl"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY" 2026-08-02) \
    || fail "empty-source daily report failed"

  count=$(printf '%s\n' "$out" | grep -c 'No activity recorded for 2026-08-02')
  [ "$count" -eq 4 ] || fail "empty sources did not report no activity for all four questions: $out"
  pass "daily report distinguishes present empty sources from unanswerable sources"
}

test_absent_and_malformed_sources_are_reported_without_failure() {
  local paths fixture_root home out
  paths=$(make_fixture absent)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  rmdir "$home/data" "$home/state"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" "$DAILY" 2026-08-02) \
    || fail "absent-source daily report failed"
  assert_contains "$out" "backlog source is absent" "absent backlog"
  assert_contains "$out" "model ledger source is absent" "absent ledger"
  assert_contains "$out" "status source is absent" "absent status"

  mkdir -p "$home/data" "$home/state"
  mkdir "$home/data/backlog.md"
  : > "$home/data/routing-outcomes.jsonl"
  printf 'not a status event\nworking [key=valid] [corr=123]: correlated event\nneeds-decision corr=0123456789abcdef [key=valid]: choose\nresolved corr=0123456789abcdef [key=valid]: chosen\n' > "$home/state/bad.status"
  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_TELEMETRY_FAIL=1 "$DAILY" 2026-08-02) \
    || fail "malformed-source daily report failed"
  assert_contains "$out" "backlog source is unreadable or malformed" "malformed backlog"
  assert_contains "$out" "model ledger source is unreadable or malformed" "malformed ledger"
  assert_contains "$out" "malformed ledger row 2" "ledger diagnostic"
  assert_contains "$out" "status lines have no timestamps" "status timestamp limitation"
  assert_contains "$out" "1 status line skipped" "unmatched status line count"
  assert_not_contains "$out" "2 status lines skipped" "multiple bracket groups accepted"
  assert_not_contains "$out" "status source is malformed" "one line does not discard the source"
  pass "daily report skips unmatched status lines without discarding valid correlated lines"
}

test_invalid_date_is_refused
test_help_describes_manual_contract
test_reports_dated_deliveries_and_terminal_outcomes
test_legacy_only_day_reports_named_gap
test_undated_done_task_reports_named_gap
test_data_and_state_overrides_select_active_home_sources
test_manual_backend_is_a_named_gap
test_captain_threads_are_not_deliveries
test_compact_output_caps_details_and_full_expands_them
test_unclassified_attempts_keep_both_refusals
test_default_today_reports_live_blockers
test_present_empty_sources_report_no_activity
test_absent_and_malformed_sources_are_reported_without_failure
