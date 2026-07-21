#!/usr/bin/env bash
# tests/fm-heartbeat.test.sh - the token-light heartbeat: provably-stale
# watcher-lock recovery (fail-closed on a live holder) and quota-wait resume
# (capacity-verified, time-based fallback, bounded backoff, never abandoned).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HB="$ROOT/bin/fm-heartbeat.sh"
QW="$ROOT/bin/fm-quota-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-heartbeat-tests)

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do p=$((p + 1)); done
  printf '%s\n' "$p"
}

new_home() {  # echo a fresh FM_HOME with an empty state dir
  local d
  mkdir -p "$TMP_ROOT"
  d=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

quota_fixture() {  # <file> <percentRemaining>
  local file=$1 pct=$2
  cat > "$file" <<EOF
{"providers":[{"provider":"claude","state":{"status":"fresh"},
  "windows":[{"id":"five_hour","percentRemaining":$pct},
             {"id":"seven_day","percentRemaining":$pct}]}]}
EOF
}

# --- stale watcher-lock recovery --------------------------------------------

test_stale_lock_cleared() {
  local home state out dp
  home=$(new_home); state="$home/state"
  dp=$(dead_pid)
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$dp" > "$state/.watch.lock/pid"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$HB" 2>&1)
  assert_contains "$out" "cleared stale lock" "stale lock (dead holder) is reported"
  assert_contains "$out" "re-arm supervision" "recovery surfaces the next step"
  assert_absent "$state/.watch.lock/pid" "the stale lock file is removed"
  pass "a provably-stale watcher lock (dead holder) is recovered"
}

test_live_lock_preserved() {
  local home state out
  home=$(new_home); state="$home/state"
  mkdir -p "$state/.watch.lock"
  # A live pid that is NOT an identity-matched healthy watcher: unhealthy, but
  # alive, so it must be left alone (fail closed).
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$HB" 2>&1)
  assert_not_contains "$out" "cleared stale lock" "a live holder is never force-unlocked"
  assert_present "$state/.watch.lock/pid" "the live lock file is preserved"
  pass "a live (even unhealthy) watcher lock is preserved - fail closed"
}

# --- quota-wait resume ------------------------------------------------------

test_resume_when_capacity_back() {
  local home state fixture out attempts
  home=$(new_home); state="$home/state"
  fixture="$home/quota.json"
  quota_fixture "$fixture" 80
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    "$QW" record parked-1 --vendor claude --relaunch 'fm-send parked-1 resume' >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$HB" --quota-json "$fixture" --now 2000 2>&1)
  assert_contains "$out" "resume parked-1" "capacity return surfaces a resume step"
  assert_contains "$out" "fm-send parked-1 resume" "the recorded relaunch is surfaced"
  attempts=$(FM_STATE_OVERRIDE="$state" "$QW" get parked-1 | jq -r '.attempts')
  [ "$attempts" = "0" ] || fail "an available entry stays due (not backed off), got attempts=$attempts"
  assert_present "$state/parked-1.quota-wait" "the entry is not dropped until firstmate clears it"
  pass "resume is surfaced when verified capacity returns, entry kept until cleared"
}

test_backoff_when_still_constrained() {
  local home state fixture out attempts due
  home=$(new_home); state="$home/state"
  fixture="$home/quota.json"
  quota_fixture "$fixture" 1
  FM_STATE_OVERRIDE="$state" FM_QUOTA_WAIT_NOW=1000 \
    "$QW" record parked-2 --vendor claude >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$HB" --quota-json "$fixture" --now 2000 2>&1)
  assert_not_contains "$out" "resume parked-2" "still-constrained work is not resumed"
  attempts=$(FM_STATE_OVERRIDE="$state" "$QW" get parked-2 | jq -r '.attempts')
  [ "$attempts" = "1" ] || fail "a constrained re-check backs off (attempts=1), got $attempts"
  due=$(FM_STATE_OVERRIDE="$state" "$QW" due --now 2000)
  assert_not_contains "$due" "parked-2" "backoff pushes next_check past now (no busy poll)"
  pass "a still-constrained entry backs off and is never busy-polled"
}

test_time_fallback_without_quota_axi() {
  local home state out
  home=$(new_home); state="$home/state"
  FM_STATE_OVERRIDE="$state" "$QW" record parked-3 --vendor opencode --wait-until 1500 \
    --relaunch 'relaunch parked-3' >/dev/null
  # No fixture and a missing quota command: capacity cannot be verified, so the
  # declared reset time drives resumption.
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_HEARTBEAT_QUOTA_AXI=/nonexistent/quota-axi "$HB" --now 2000 2>&1)
  assert_contains "$out" "resume parked-3" "elapsed reset time resumes when capacity is unverifiable"
  assert_contains "$out" "wait window elapsed" "the fallback reason is time-based, not a false capacity claim"
  pass "unverifiable vendor falls back to the recorded reset time"
}

test_no_output_when_nothing_actionable() {
  local home state out
  home=$(new_home); state="$home/state"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_HEARTBEAT_QUOTA_AXI=/nonexistent/quota-axi "$HB" --now 2000 2>&1)
  [ -z "$out" ] || fail "an idle heartbeat must be silent, got: $out"
  pass "an idle heartbeat prints nothing (token-light)"
}

test_stale_lock_cleared
test_live_lock_preserved
test_resume_when_capacity_back
test_backoff_when_still_constrained
test_time_fallback_without_quota_axi
test_no_output_when_nothing_actionable
