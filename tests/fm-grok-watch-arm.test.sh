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
  [ "$(grep -cF 'watcher: FAILED - fixture arm failure' "$out")" -eq 1 ] || fail "same-owner arm failure was emitted more than once"
  pass "arm failure completes the Grok task loudly"
}

test_output_overflow_retires_child_and_fails_once() {
  local home arm out status child failure
  home=$(make_home output-overflow)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/overflow-child-pid"
trap 'exit 143' TERM
while :; do printf '0123456789abcdef0123456789abcdef\n'; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 "$OWNER" > "$out" 2>&1
  status=$?
  expect_code 1 "$status" "output overflow must fail the Grok tracked task"
  child=$(cat "$home/state/overflow-child-pid")
  kill -0 "$child" 2>/dev/null && fail "output overflow left the arm child alive"
  failure='watcher: FAILED - Grok continuity arm output exceeded 128 bytes'
  [ "$(grep -cF "$failure" "$out")" -eq 1 ] || fail "same-owner overflow failure was not emitted exactly once"
  pass "bounded output overflow retires the child and fails once"
}

test_transferred_output_overflow_queues_once() {
  local home arm out pid child failure
  home=$(make_home transferred-output-overflow)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/overflow-child-pid"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while [ ! -e "$FM_HOME/state/release-overflow" ]; do sleep 0.05; done
trap 'exit 143' TERM
while :; do printf '0123456789abcdef0123456789abcdef\n'; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/overflow-child-pid" || fail "transferred overflow child did not start"
  : > "$home/state/.afk"
  : > "$home/state/release-overflow"
  wait_for_file "$home/state/.wake-queue" || fail "transferred overflow failure was not queued"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "transferred overflow completed the old Grok task"
  child=$(cat "$home/state/overflow-child-pid")
  kill -0 "$child" 2>/dev/null && fail "transferred overflow left the arm child alive"
  failure='watcher: FAILED - Grok continuity arm output exceeded 128 bytes'
  [ "$(grep -cF "$failure" "$home/state/.wake-queue")" -eq 1 ] || fail "transferred overflow failure was not queued exactly once"
  assert_not_contains "$(cat "$out")" "$failure" "old owner emitted transferred overflow failure"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "transferred bounded overflow queues once without completing"
}

test_no_newline_output_overflow_is_bounded() {
  local home arm out status child failure size
  home=$(make_home no-newline-overflow)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/overflow-child-pid"
trap 'exit 143' TERM
while :; do printf '0123456789abcdef0123456789abcdef'; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 "$OWNER" > "$out" 2>&1
  status=$?
  expect_code 1 "$status" "no-newline overflow must fail the Grok tracked task"
  child=$(cat "$home/state/overflow-child-pid")
  kill -0 "$child" 2>/dev/null && fail "no-newline overflow left the arm child alive"
  failure='watcher: FAILED - Grok continuity arm output exceeded 128 bytes'
  [ "$(grep -cF "$failure" "$out")" -eq 1 ] || fail "no-newline overflow failure was not emitted exactly once"
  size=$(wc -c < "$out" | tr -d '[:space:]')
  [ "$size" -le 256 ] || fail "no-newline overflow produced unbounded owner output: $size bytes"
  pass "no-newline output is bounded and retires the child"
}

test_term_resistant_overflow_is_forced_bounded() {
  local home arm out status child descendant failure started elapsed
  home=$(make_home term-resistant-overflow)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
trap '' TERM PIPE
(trap '' TERM; while :; do sleep 1; done) &
printf '%s\n' "$!" > "$FM_HOME/state/overflow-descendant-pid"
printf '%s\n' "$$" > "$FM_HOME/state/overflow-child-pid"
while :; do printf '0123456789abcdef0123456789abcdef'; done
SH
  chmod +x "$arm"

  started=$(date +%s)
  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 FM_GROK_WATCH_CHILD_TERM_GRACE=0.2 "$OWNER" > "$out" 2>&1
  status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 1 "$status" "TERM-resistant overflow must fail the Grok tracked task"
  [ "$elapsed" -le 5 ] || fail "TERM-resistant overflow retirement exceeded its bound"
  child=$(cat "$home/state/overflow-child-pid")
  descendant=$(cat "$home/state/overflow-descendant-pid")
  kill -0 "$child" 2>/dev/null && fail "TERM-resistant overflow left the exact child alive"
  descendant_state=$(ps -o stat= -p "$descendant" 2>/dev/null | tr -d ' ' || true)
  case "$descendant_state" in ''|Z*) ;; *) fail "TERM-resistant overflow left its descendant alive ($descendant_state)" ;; esac
  failure='watcher: FAILED - Grok continuity arm output exceeded 128 bytes'
  [ "$(grep -cF "$failure" "$out")" -eq 1 ] || fail "TERM-resistant overflow failure was not emitted exactly once"
  pass "TERM-resistant overflow forcibly retires its exact process tree"
}

test_retirement_identity_mismatch_preserves_unrelated_process() {
  local home arm out status unrelated identity fake_seed failure
  home=$(make_home retirement-identity-mismatch)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  sleep 300 &
  unrelated=$!
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$unrelated") \
    || fail "could not identify unrelated retirement counterfactual"
  fake_seed="$home/state/fake-overflow-identities"
  printf '%s\t%s-mismatch\n' "$unrelated" "$identity" > "$fake_seed"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do printf '0123456789abcdef0123456789abcdef'; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 \
    FM_GROK_WATCH_CHILD_TERM_GRACE=0.2 FM_GROK_WATCH_RETIRE_TEST_SEED="$fake_seed" "$OWNER" > "$out" 2>&1
  status=$?
  expect_code 1 "$status" "identity-mismatch retirement must fail through the typed boundary"
  kill -0 "$unrelated" 2>/dev/null || fail "identity mismatch killed an unrelated process"
  failure='exact child retirement was incomplete'
  assert_contains "$(cat "$out")" "$failure" "identity mismatch did not surface incomplete retirement"
  kill -TERM "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  pass "retirement skips changed identities and preserves unrelated processes"
}

test_retirement_reparented_identity_is_not_forced() {
  local home arm out status escaped identity fake_seed failure
  home=$(make_home retirement-reparented-identity)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  bash -c 'trap "" TERM; while :; do sleep 1; done' &
  escaped=$!
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$escaped") \
    || fail "could not identify reparented retirement counterfactual"
  fake_seed="$home/state/fake-overflow-identities"
  printf '%s\t%s\n' "$escaped" "$identity" > "$fake_seed"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do printf '0123456789abcdef0123456789abcdef'; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 \
    FM_GROK_WATCH_CHILD_TERM_GRACE=0.2 FM_GROK_WATCH_RETIRE_TEST_SEED="$fake_seed" "$OWNER" > "$out" 2>&1
  status=$?
  expect_code 1 "$status" "reparented identity retirement must fail through the typed boundary"
  kill -0 "$escaped" 2>/dev/null || fail "unchanged reparented identity was forcibly signaled"
  failure='exact child retirement was incomplete'
  assert_contains "$(cat "$out")" "$failure" "reparented identity did not surface incomplete retirement"
  kill -KILL "$escaped" 2>/dev/null || true
  wait "$escaped" 2>/dev/null || true
  pass "retirement skips unchanged identities outside the current tree"
}

test_transferred_no_newline_overflow_queues_once() {
  local home arm out pid child failure size
  home=$(make_home transferred-no-newline-overflow)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/overflow-child-pid"
while [ ! -e "$FM_HOME/state/release-overflow" ]; do sleep 0.05; done
trap 'exit 143' TERM
while :; do printf '0123456789abcdef0123456789abcdef'; done
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_OUTPUT_MAX_BYTES=128 FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/overflow-child-pid" || fail "transferred no-newline child did not start"
  : > "$home/state/.afk"
  : > "$home/state/release-overflow"
  wait_for_file "$home/state/.wake-queue" || fail "transferred no-newline failure was not queued"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "transferred no-newline overflow completed the old task"
  child=$(cat "$home/state/overflow-child-pid")
  kill -0 "$child" 2>/dev/null && fail "transferred no-newline overflow left the child alive"
  failure='watcher: FAILED - Grok continuity arm output exceeded 128 bytes'
  [ "$(grep -cF "$failure" "$home/state/.wake-queue")" -eq 1 ] || fail "transferred no-newline failure was not queued exactly once"
  assert_not_contains "$(cat "$out")" "$failure" "old owner emitted transferred no-newline failure"
  size=$(wc -c < "$out" | tr -d '[:space:]')
  [ "$size" -le 128 ] || fail "transferred no-newline overflow produced unbounded output: $size bytes"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "transferred no-newline overflow stays bounded and queues once"
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

test_actionable_close_after_away_transfer_stays_dormant() {
  local home arm out pid count
  home=$(make_home actionable-away-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '1\t1\tsignal\ttask\tsignal: away-owned action\n' > "$FM_HOME/state/.wake-queue"
: > "$FM_HOME/state/.afk"
printf 'signal: away-owned action\n'
SH
  chmod +x "$arm"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/.afk" || fail "actionable away-transfer arm did not finish"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "actionable close completed after away mode took supervision"
  [ -s "$home/state/.wake-queue" ] || fail "old Grok owner consumed away mode's durable wake"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "an actionable close stays dormant when away mode takes supervision"
}

test_actionable_close_after_session_transfer_stays_dormant() {
  local home arm out pid replacement
  home=$(make_home actionable-session-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  replacement=$$
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '1\t1\tsignal\ttask\tsignal: successor-owned action\n' > "$FM_HOME/state/.wake-queue"
printf '%s\n' "$REPLACEMENT_OWNER" > "$FM_HOME/state/.lock"
printf 'signal: successor-owned action\n'
SH
  chmod +x "$arm"

  FM_HOME="$home" REPLACEMENT_OWNER="$replacement" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$home/state/.lock" 2>/dev/null || true)" = "$replacement" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(cat "$home/state/.lock")" = "$replacement" ] || fail "actionable session-transfer arm did not change ownership"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "actionable close completed after the session lock transferred"
  [ -s "$home/state/.wake-queue" ] || fail "old Grok owner consumed the successor's durable wake"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "an actionable close stays dormant after session-lock ownership transfers"
}

hold_wake_queue_lock() {
  local home=$1
  (
    FM_HOME="$home"
    STATE="$home/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK" || exit 1
    : > "$home/state/classification-blocked"
    while [ ! -e "$home/state/release-classification" ]; do sleep 0.05; done
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  ) &
  CLASSIFICATION_LOCK_PID=$!
  wait_for_file "$home/state/classification-blocked" || fail "could not hold wake queue lock"
}

test_away_transfer_during_actionable_classification_stays_dormant() {
  local home arm out pid
  home=$(make_home classification-away-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '1\t1\tsignal\ttask\tsignal: classified away action\n' > "$FM_HOME/state/.wake-queue"
: > "$FM_HOME/state/arm-closed"
printf 'signal: classified away action\n'
SH
  chmod +x "$arm"
  hold_wake_queue_lock "$home"
  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-closed" || fail "classification away-transfer arm did not close"
  sleep 0.1
  : > "$home/state/.afk"
  : > "$home/state/release-classification"
  wait "$CLASSIFICATION_LOCK_PID" || fail "wake queue lock holder failed"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "actionable classification completed after away mode took supervision"
  [ -s "$home/state/.wake-queue" ] || fail "old Grok owner consumed away mode's classified wake"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "away transfer during actionable classification keeps the old owner dormant"
}

test_session_transfer_during_actionable_classification_stays_dormant() {
  local home arm out pid replacement
  home=$(make_home classification-session-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  replacement=$$
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf '1\t1\tsignal\ttask\tsignal: classified successor action\n' > "$FM_HOME/state/.wake-queue"
: > "$FM_HOME/state/arm-closed"
printf 'signal: classified successor action\n'
SH
  chmod +x "$arm"
  hold_wake_queue_lock "$home"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-closed" || fail "classification session-transfer arm did not close"
  sleep 0.1
  printf '%s\n' "$replacement" > "$home/state/.lock"
  : > "$home/state/release-classification"
  wait "$CLASSIFICATION_LOCK_PID" || fail "wake queue lock holder failed"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "actionable classification completed after session ownership transferred"
  [ -s "$home/state/.wake-queue" ] || fail "old Grok owner consumed the successor's classified wake"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "session transfer during actionable classification keeps the old owner dormant"
}

test_away_transfer_during_failed_classification_stays_dormant() {
  local home arm out pid failure rows
  home=$(make_home failed-classification-away-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/arm-closed"
printf 'signal: classification will fail\n'
SH
  chmod +x "$arm"
  hold_wake_queue_lock "$home"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-closed" || fail "failed-classification away arm did not close"
  sleep 0.1
  : > "$home/state/.afk"
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "classification failure completed after away mode took supervision"
  : > "$home/state/release-classification"
  wait "$CLASSIFICATION_LOCK_PID" || fail "wake queue lock holder failed"
  failure='watcher: FAILED - Grok continuity could not classify a completed arm: wake queue lock remained unavailable'
  wait_for_file "$home/state/.wake-queue" || fail "classification failure was not queued for away supervision"
  rows=$(cat "$home/state/.wake-queue")
  assert_contains "$rows" "$failure" "away successor could not see the exact classification failure"
  sleep 0.2
  [ "$(grep -cF "$failure" "$home/state/.wake-queue")" -eq 1 ] || fail "away classification failure was queued more than once"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_not_contains "$(cat "$out")" "watcher: FAILED - Grok continuity could not classify" "old owner surfaced classification failure after away transfer"
  pass "away transfer during failed classification keeps the old owner dormant"
}

test_session_transfer_during_failed_classification_stays_dormant() {
  local home arm out pid replacement failure rows
  home=$(make_home failed-classification-session-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  replacement=$$
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/arm-closed"
printf 'signal: classification will fail\n'
SH
  chmod +x "$arm"
  hold_wake_queue_lock "$home"
  printf 'pending:handling:existing-generation\n' > "$home/state/.watcher-down"

  FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/arm-closed" || fail "failed-classification session arm did not close"
  sleep 0.1
  printf '%s\n' "$replacement" > "$home/state/.lock"
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "classification failure completed after session ownership transferred"
  : > "$home/state/release-classification"
  wait "$CLASSIFICATION_LOCK_PID" || fail "wake queue lock holder failed"
  failure='watcher: FAILED - Grok continuity could not classify a completed arm: wake queue lock remained unavailable'
  wait_for_file "$home/state/.wake-queue" || fail "classification failure was not queued for successor supervision"
  rows=$(cat "$home/state/.wake-queue")
  assert_contains "$rows" "$failure" "session successor could not see the exact classification failure"
  sleep 0.2
  [ "$(grep -cF "$failure" "$home/state/.wake-queue")" -eq 1 ] || fail "session classification failure was queued more than once"
  [ "$(cat "$home/state/.watcher-down")" = 'pending:handling:existing-generation' ] || fail "failure publication clobbered active recovery handling"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_not_contains "$(cat "$out")" "watcher: FAILED - Grok continuity could not classify" "old owner surfaced classification failure after session transfer"
  pass "session transfer during failed classification keeps the old owner dormant"
}

make_blocking_failure_grep() {
  local home=$1 real_grep
  real_grep=$(command -v grep)
  mkdir -p "$home/test-bin"
  cat > "$home/test-bin/grep" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"^watcher: FAILED"*)
    : > "\$FM_HOME/state/failure-classification-blocked"
    while [ ! -e "\$FM_HOME/state/release-failure-classification" ]; do sleep 0.05; done
    ;;
esac
exec "$real_grep" "\$@"
SH
  chmod +x "$home/test-bin/grep"
}

test_away_transfer_during_arm_failure_classification_stays_dormant() {
  local home arm out pid failure
  home=$(make_home arm-failure-away-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - classified after away transfer\n'
exit 7
SH
  chmod +x "$arm"
  make_blocking_failure_grep "$home"

  PATH="$home/test-bin:$PATH" FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/failure-classification-blocked" || fail "arm failure classification did not block"
  : > "$home/state/.afk"
  : > "$home/state/release-failure-classification"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "arm failure completed after away mode took supervision"
  failure='watcher: FAILED - classified after away transfer'
  wait_for_file "$home/state/.wake-queue" || fail "arm failure was not queued for away supervision"
  assert_contains "$(cat "$home/state/.wake-queue")" "$failure" "away successor could not see the exact arm failure"
  sleep 0.2
  [ "$(grep -cF "$failure" "$home/state/.wake-queue")" -eq 1 ] || fail "away arm failure was queued more than once"
  assert_not_contains "$(cat "$out")" "$failure" "old owner emitted arm failure after away transfer"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "away transfer during arm failure classification keeps the old owner dormant"
}

test_session_transfer_during_arm_failure_classification_stays_dormant() {
  local home arm out pid replacement failure
  home=$(make_home arm-failure-session-transfer)
  arm="$home/fake-arm.sh"
  out="$home/owner.out"
  replacement=$$
  cat > "$arm" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - classified after session transfer\n'
exit 7
SH
  chmod +x "$arm"
  make_blocking_failure_grep "$home"

  PATH="$home/test-bin:$PATH" FM_HOME="$home" FM_GROK_WATCH_ARM_SCRIPT="$arm" FM_GROK_WATCH_IDLE_POLL=0.05 "$OWNER" > "$out" 2>&1 &
  pid=$!
  wait_for_file "$home/state/failure-classification-blocked" || fail "arm failure classification did not block"
  printf '%s\n' "$replacement" > "$home/state/.lock"
  : > "$home/state/release-failure-classification"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || fail "arm failure completed after session ownership transferred"
  failure='watcher: FAILED - classified after session transfer'
  wait_for_file "$home/state/.wake-queue" || fail "arm failure was not queued for successor supervision"
  assert_contains "$(cat "$home/state/.wake-queue")" "$failure" "session successor could not see the exact arm failure"
  sleep 0.2
  [ "$(grep -cF "$failure" "$home/state/.wake-queue")" -eq 1 ] || fail "session arm failure was queued more than once"
  assert_not_contains "$(cat "$out")" "$failure" "old owner emitted arm failure after session transfer"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  pass "session transfer during arm failure classification keeps the old owner dormant"
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
test_output_overflow_retires_child_and_fails_once
test_transferred_output_overflow_queues_once
test_no_newline_output_overflow_is_bounded
test_term_resistant_overflow_is_forced_bounded
test_retirement_identity_mismatch_preserves_unrelated_process
test_retirement_reparented_identity_is_not_forced
test_transferred_no_newline_overflow_queues_once
test_open_decision_completes_without_queue_row
test_pending_recovery_completes_without_queue_row
test_malformed_recovery_fails_closed
test_no_supervision_need_stays_dormant_until_work_returns
test_away_mode_stays_dormant_until_normal_supervision_returns
test_changed_session_owner_stays_dormant
test_actionable_close_after_away_transfer_stays_dormant
test_actionable_close_after_session_transfer_stays_dormant
test_away_transfer_during_actionable_classification_stays_dormant
test_session_transfer_during_actionable_classification_stays_dormant
test_away_transfer_during_failed_classification_stays_dormant
test_session_transfer_during_failed_classification_stays_dormant
test_away_transfer_during_arm_failure_classification_stays_dormant
test_session_transfer_during_arm_failure_classification_stays_dormant
test_owner_signal_retires_arm_child
