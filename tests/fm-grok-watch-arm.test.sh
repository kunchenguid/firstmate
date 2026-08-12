#!/usr/bin/env bash
# Regression for Grok's persistent tracked background watcher owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-watch-arm-grok.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-watch-arm)
ln -s /bin/sleep "$TMP_ROOT/grok"
"$TMP_ROOT/grok" 300 &
SESSION_OWNER=$!

cleanup_grok_owner() {
  kill -TERM "$SESSION_OWNER" 2>/dev/null || true
  wait "$SESSION_OWNER" 2>/dev/null || true
  fm_test_cleanup
}

trap cleanup_grok_owner EXIT
trap 'cleanup_grok_owner; exit 130' INT
trap 'cleanup_grok_owner; exit 143' TERM

wait_for_file() {
  local file=$1 attempts=${2:-100} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -e "$file" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_exit() {
  local pid=$1 attempts=${2:-100} i=0
  while [ "$i" -lt "$attempts" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/task.meta"
  printf '%s\n' "$SESSION_OWNER" > "$home/state/.lock"
  printf '%s\n' "$home"
}

test_empty_close_rearms_without_completing_grok_task() {
  local home arm out pid count
  home=$(make_home empty-close)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
set -u
count_file="$FM_HOME/state/arm-count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  printf 'signal: already handled before Grok could be notified\n'
  exit 0
fi
while [ ! -e "$FM_HOME/state/release-actionable" ]; do sleep 0.05; done
printf '1\t1\tsignal\ttask\tsignal: actionable\n' > "$FM_HOME/state/.wake-queue"
printf 'signal: actionable\n'
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-count" || fail "Grok owner never launched its first arm"
  i=0
  while [ "$i" -lt 100 ]; do
    count=$(cat "$home/state/arm-count" 2>/dev/null || echo 0)
    [ "$count" -ge 2 ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ "${count:-0}" -ge 2 ] || fail "empty arm close did not re-arm inside the same tracked command"
  kill -0 "$pid" 2>/dev/null || fail "empty arm close completed Grok's tracked command and would bill a model turn"

  : > "$home/state/release-actionable"
  wait_for_exit "$pid" || fail "durable actionable wake did not complete Grok's tracked command"
  wait "$pid" || fail "Grok owner failed after a durable actionable wake"
  assert_contains "$(cat "$out")" "signal: actionable" "actionable reason was not preserved"
  pass "empty close re-arms internally while a durable actionable wake completes the tracked Grok task"
}

test_failure_completes_loudly() {
  local home arm out status
  home=$(make_home failure)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - fixture arm failure\n'
exit 7
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" "$OWNER" > "$out" 2>&1
  status=$?
  expect_code 7 "$status" "arm failure must propagate through Grok's tracked task"
  assert_contains "$(cat "$out")" "watcher: FAILED - fixture arm failure" "arm failure text was suppressed"
  pass "arm failure completes the Grok task loudly"
}

test_open_decision_completes_without_queue_row() {
  local home arm out
  home=$(make_home open-decision)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'needs-decision: choose the safe path [key=path]\n' >> "$FM_HOME/state/task.status"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" "$OWNER" > "$out" 2>&1 \
    || fail "open decision did not complete Grok's tracked task"
  pass "an OPEN DECISIONS entry completes the Grok task even without a queue row"
}

test_pending_recovery_completes_without_queue_row() {
  local home arm out
  home=$(make_home pending-recovery)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  printf 'pending:downtime:fixture-generation\n' > "$home/state/.watcher-down"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" "$OWNER" > "$out" 2>&1 \
    || fail "pending recovery episode did not complete Grok's tracked task"
  pass "a pending recovery episode completes the Grok task even without a queue row"
}

test_malformed_recovery_fails_closed() {
  local home arm out status
  home=$(make_home malformed-recovery)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  printf 'not-a-valid-recovery-marker\n' > "$home/state/.watcher-down"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" "$OWNER" > "$out" 2>&1
  status=$?
  expect_code 1 "$status" "malformed recovery state must fail closed"
  assert_contains "$(cat "$out")" "watcher: FAILED - Grok continuity could not classify" "classification failure was not surfaced"
  pass "malformed recovery state completes the Grok task with a loud failure"
}

test_no_supervision_need_stays_dormant_until_work_returns() {
  local home arm out pid count
  home=$(make_home dormant)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
set -u
count_file="$FM_HOME/state/arm-count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  rm -f "$FM_HOME/state/task.meta"
  exit 0
fi
printf '1\t1\tcheck\ttask\tcheck: resumed\n' > "$FM_HOME/state/.wake-queue"
printf 'check: resumed\n'
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-count" || fail "dormant case never launched its first arm"
  sleep 0.2
  count=$(cat "$home/state/arm-count")
  [ "$count" -eq 1 ] || fail "owner kept arming after supervision need ended"
  kill -0 "$pid" 2>/dev/null || fail "no-need close completed Grok's task and would bill an empty turn"

  : > "$home/state/task.meta"
  wait_for_exit "$pid" || fail "owner did not resume after supervision need returned"
  wait "$pid" || fail "resumed actionable wake failed"
  [ "$(cat "$home/state/arm-count")" -eq 2 ] || fail "owner did not launch exactly one resumed arm"
  pass "an empty close with no supervision need stays dormant until work returns"
}

test_away_mode_stays_dormant_until_normal_supervision_returns() {
  local home arm out pid count
  home=$(make_home away-mode)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
set -u
count_file="$FM_HOME/state/arm-count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -eq 1 ]; then
  : > "$FM_HOME/state/.afk"
  exit 0
fi
printf '1\t1\tcheck\ttask\tcheck: normal supervision resumed\n' > "$FM_HOME/state/.wake-queue"
printf 'check: normal supervision resumed\n'
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/.afk" || fail "away-mode case never completed its first empty arm"
  sleep 0.2
  count=$(cat "$home/state/arm-count")
  [ "$count" -eq 1 ] || fail "persistent Grok owner competed with away-mode supervision"
  kill -0 "$pid" 2>/dev/null || fail "away-mode handoff completed Grok's task and would bill an empty turn"

  rm -f "$home/state/.afk"
  wait_for_exit "$pid" || fail "Grok owner did not resume after away mode ended"
  wait "$pid" || fail "post-away actionable wake failed"
  [ "$(cat "$home/state/arm-count")" -eq 2 ] || fail "Grok owner did not launch exactly one post-away arm"
  pass "away mode keeps the Grok owner dormant until normal supervision returns"
}

test_changed_session_owner_stays_dormant() {
  local home arm out pid count
  home=$(make_home session-owner-change)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
count_file="$FM_HOME/state/arm-count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-count" || fail "session-owner case never launched its first arm"
  printf '%s\n' "$$" > "$home/state/.lock"
  sleep 0.2
  count=$(cat "$home/state/arm-count")
  [ "$count" -eq 1 ] || fail "old Grok owner re-armed after the fleet lock changed sessions"
  kill -0 "$pid" 2>/dev/null || fail "lost session ownership completed Grok's task and would bill an empty turn"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "a Grok task whose session lost the fleet lock stays dormant and does not re-arm"
}

test_owner_signal_retires_arm_child() {
  local home arm out pid child status
  home=$(make_home signal-cleanup)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/child-pid"
trap 'exit 143' TERM
while :; do sleep 0.1; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/child-pid" || fail "signal cleanup case never launched its arm child"
  child=$(cat "$home/state/child-pid")
  kill -TERM "$pid"
  wait "$pid"
  status=$?
  expect_code 143 "$status" "Grok owner must preserve its termination status"
  kill -0 "$child" 2>/dev/null && fail "terminating the Grok owner left its arm child alive"
  pass "terminating the tracked Grok owner retires its arm child"
}

test_empty_close_rearms_without_completing_grok_task
test_failure_completes_loudly
test_open_decision_completes_without_queue_row
test_pending_recovery_completes_without_queue_row
test_malformed_recovery_fails_closed
test_no_supervision_need_stays_dormant_until_work_returns
test_away_mode_stays_dormant_until_normal_supervision_returns
test_changed_session_owner_stays_dormant
test_owner_signal_retires_arm_child
