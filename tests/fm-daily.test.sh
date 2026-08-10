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
  mkdir -p "$fixture_root/bin" "$home/data" "$home/state"
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
EOF
  : > "$home/data/routing-outcomes.jsonl"
  printf 'working: undated event\nfailed: undated failure\n' > "$home/state/active-a.status"
  ledger=$(jq -cn \
    --argjson accepted "$(ledger_row accepted none 2026-08-02T12:00:00Z 2026-08-02T12:01:00Z codex gpt-5.6-sol high 60)" \
    --argjson failed "$(ledger_row failed tool 2026-08-02T13:00:00Z 2026-08-02T13:02:00Z claude opus xhigh 120)" \
    --argjson incomplete "$(ledger_row incomplete unknown 2026-08-02T14:00:00Z '' grok grok-4 medium null)" \
    '[$accepted,$failed,$incomplete]')

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON="$ledger" "$DAILY" 2026-08-02) \
    || fail "dated daily report failed"

  assert_contains "$out" "Daily report - 2026-08-02" "dated report heading"
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

test_default_today_reports_live_blockers() {
  local paths fixture_root home out today
  paths=$(make_fixture blockers)
  fixture_root=$(printf '%s\n' "$paths" | sed -n '1p')
  home=$(printf '%s\n' "$paths" | sed -n '2p')
  today=$(date +%F)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] prerequisite-a - Prerequisite work (repo: alpha) (kind: ship)

## Queued
- [ ] blocked-a - Waiting delivery (repo: beta) (kind: ship) blocked-by: prerequisite-a - dependency not merged
- [ ] held-a - Awaiting approval (repo: gamma) (kind: scout) (hold: captain decision pending) (hold-kind: captain)

## Done
EOF
  : > "$home/data/routing-outcomes.jsonl"

  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_LEDGER_JSON='[]' "$DAILY") \
    || fail "default daily report failed"

  assert_contains "$out" "Daily report - $today" "default date"
  assert_contains "$out" "blocked-a [beta/ship]: Waiting delivery - blocked by prerequisite-a" "live dependency blocker"
  assert_contains "$out" "held-a [gamma/scout]: Awaiting approval - held (captain): captain decision pending" "live hold"
  pass "daily report defaults to today and reports structured live blockers"
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
  printf 'not a status event\n' > "$home/state/bad.status"
  out=$(FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$home" FM_TEST_TELEMETRY_FAIL=1 "$DAILY" 2026-08-02) \
    || fail "malformed-source daily report failed"
  assert_contains "$out" "backlog source is unreadable or malformed" "malformed backlog"
  assert_contains "$out" "model ledger source is unreadable or malformed" "malformed ledger"
  assert_contains "$out" "malformed ledger row 2" "ledger diagnostic"
  assert_contains "$out" "status source is malformed" "malformed status"
  pass "daily report preserves absent and malformed source distinctions while exiting zero"
}

test_invalid_date_is_refused
test_reports_dated_deliveries_and_terminal_outcomes
test_default_today_reports_live_blockers
test_present_empty_sources_report_no_activity
test_absent_and_malformed_sources_are_reported_without_failure
