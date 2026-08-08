#!/usr/bin/env bash
# Cursor stop-hook adapter tests — extracted from tests/fm-turnend-guard.test.sh
# (code-judo finding #4). The shared guard suite sources this file so the
# Cursor-specific test functions are available to the test list while staying
# in a focused, harness-scoped file.
#
# Depends on helpers defined in tests/fm-turnend-guard.test.sh:
#   install_guard_scripts, make_turnend_case, run_turnend_guard, and
#   the shared assertion functions from tests/lib.sh.

# --- HOOK: bin/fm-turnend-guard-cursor.sh -----------------------------------
# Cursor's stop hook does not honour exit 2 as a forced continuation, so the
# shim translates the shared guard's blind-turn signal into a followup_message
# body. Every stop is evaluated, including a loop_count>0 continuation, so a
# follow-up turn that ends blind re-arms; persistent state bounds repeated
# failures and re-firing reasons without charging distinct progress. A typed
# actionable arm close gets a normal wake followup; an arm failure keeps the
# loud blind banner. Verified against cursor-agent 2026.07.23-e383d2b.

# The shim runs bin/fm-watch-arm.sh inside the fixture. These stubs stand in
# for the real arm wrapper so the test controls whether the arm succeeds
# (leaving a live identity-matched watcher lock with a fresh beacon, which the
# re-run guard reads as healthy) or fails, and record every invocation.
install_failing_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\\n' >> "$dir/state/.arm-invocations"
printf '%s\\n' "\${FM_CHECK_INTERVAL:-}" >> "$dir/state/.arm-cadence"
exit 1
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_actionable_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\\n' >> "$dir/state/.arm-invocations"
printf 'signal: task.status\\n'
exit 0
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_succeeding_arm_stub() {
  local dir=$1 root
  root=$(cd "$dir" && pwd)
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\n' >> "$dir/state/.arm-invocations"
sleep 60 &
pid=\$!
identity=\$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "\$1"; fm_pid_identity "\$2"' _ "$dir/bin/fm-wake-lib.sh" "\$pid")
mkdir -p "$dir/state/.watch.lock"
printf '%s\n' "\$pid" > "$dir/state/.watch.lock/pid"
printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
printf '%s\n' "$root/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
printf '%s\n' "\$identity" > "$dir/state/.watch.lock/pid-identity"
touch "$dir/state/.last-watcher-beat"
exit 0
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

test_cursor_shim_emits_followup_on_block() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-block")
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  # No live watcher, so the shared guard blocks (exit 2) with its banner; the
  # arm fails, the re-run still blocks, and the turn would still end blind.
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 after translating a block into a followup_message"
  case "$out" in
    '{"followup_message":"'*'TURN WOULD END BLIND'*) : ;;
    *) fail "cursor shim must emit a followup_message carrying the guard banner, got: $out" ;;
  esac
  grep -q '^arm-invoked$' "$dir/state/.arm-invocations" 2>/dev/null \
    || fail "cursor shim must attempt the arm before deciding the turn still ends blind"
  pass "fm-turnend-guard-cursor: translates a still-blind post-arm turn into a followup_message body"
}

test_cursor_shim_wakes_after_actionable_arm() {
  local dir out json status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-actionable")
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  json=$(printf '%s\n' "$out" | tail -n 1)
  expect_code 0 "$status" "cursor shim must exit 0 after an actionable arm close"
  assert_contains "$json" "firstmate watcher wake" \
    "cursor shim must identify an actionable arm close as a normal wake"
  assert_contains "$json" "bin/fm-wake-drain.sh" \
    "cursor wake followup must instruct wake draining"
  assert_not_contains "$json" "TURN WOULD END BLIND" \
    "cursor actionable wake must not reuse the blind-turn banner"
  assert_not_contains "$json" ".cursor/hooks.json" \
    "cursor actionable wake must not suggest hook repair"
  assert_not_contains "$json" "bin/fm-watch-arm.sh" \
    "cursor actionable wake must not suggest manual watcher arming"
  grep -q '^arm-invoked$' "$dir/state/.arm-invocations" 2>/dev/null \
    || fail "cursor shim must invoke the arm before delivering an actionable wake"
  pass "fm-turnend-guard-cursor: typed actionable arm close emits a normal drain-and-handle wake"
}

test_cursor_shim_reports_temp_state_failure() {
  local dir fakebin out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-temp-failure")
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  fakebin=$(fm_fakebin "$TMP_ROOT/cursor-shim-temp-failure-bin")
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mktemp"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | PATH="$fakebin:$PATH" CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must keep a diagnostic when mktemp fails"
  assert_contains "$out" "TURN WOULD END BLIND" \
    "temporary-state failure must not silently allow a needed stop"
  [ -s "$dir/state/.arm-invocations" ] || fail "temporary-state failure must still run guard and arm handling"
  pass "fm-turnend-guard-cursor: mktemp failure stays loud"
}

test_cursor_shim_arms_then_allows() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-arm-ok")
  : > "$dir/state/task1.meta"
  install_succeeding_arm_stub "$dir"
  # The shared guard blocks, the arm succeeds (live watcher lock + fresh
  # beacon), the re-run guard allows, and the shim emits {}.
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  expect_code 0 "$status" "cursor shim must exit 0 after a successful arm"
  [ "$out" = '{}' ] || fail "cursor shim must emit {} when the arm succeeded, got: $out"
  grep -q '^arm-invoked$' "$dir/state/.arm-invocations" 2>/dev/null \
    || fail "cursor shim must foreground the arm wrapper on a blind turn"
  pass "fm-turnend-guard-cursor: parks in the arm wrapper and emits {} when the re-run guard allows"
}

test_cursor_shim_allows_when_healthy() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-allow")
  install_failing_arm_stub "$dir"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must allow a healthy stop"
  [ "$out" = '{}' ] || fail "cursor shim must emit {} on an allowed stop, got: $out"
  [ ! -e "$dir/state/.arm-invocations" ] || fail "cursor shim must not arm when the shared guard allows the stop"
  pass "fm-turnend-guard-cursor: emits {} without arming when the shared guard allows the stop"
}

test_cursor_shim_refuses_silent_stop_on_interrupt_marker() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-interrupt-marker")
  printf 'ts=1754000000\tsignal=TERM\torigin=attached\n' > "$dir/state/.hook-arm-interrupted"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 when refusing a silent stop for an interrupted park"
  assert_contains "$out" "Hook-owned supervision was interrupted" \
    "cursor shim must diagnose the interrupted park instead of a silent {}"
  assert_contains "$out" "bin/fm-wake-drain.sh" \
    "cursor interrupt followup must instruct wake draining"
  [ "$out" != '{}' ] || fail "cursor shim must not emit a silent {} while the interrupt marker exists"
  pass "fm-turnend-guard-cursor: refuses {} while the arm-interrupted marker exists"
}

test_cursor_shim_refuses_silent_stop_on_undelivered_queue() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-queued-wake")
  printf '1754000000\t1\tsignal\ttask.status\tstatus: working\n' > "$dir/state/.wake-queue"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 when refusing a silent stop for a queued wake"
  assert_contains "$out" "wake records are queued" \
    "cursor shim must surface the undelivered queue instead of a silent {}"
  assert_contains "$out" "bin/fm-wake-drain.sh" \
    "cursor queue followup must instruct wake draining"
  [ "$out" != '{}' ] || fail "cursor shim must not emit a silent {} while a wake is queued"
  pass "fm-turnend-guard-cursor: refuses {} while an undelivered wake is queued"
}

test_cursor_shim_recovers_silent_stop_after_drain() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-interrupt-recover")
  printf 'ts=1754000000\tsignal=TERM\torigin=attached\n' > "$dir/state/.hook-arm-interrupted"
  printf '1754000000\t1\tsignal\ttask.status\tstatus: working\n' > "$dir/state/.wake-queue"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 on the loud pre-drain stop"
  assert_contains "$out" "bin/fm-wake-drain.sh" \
    "pre-drain stop must tell firstmate to drain and reconcile"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "drain after the interrupted park failed"
  [ ! -e "$dir/state/.hook-arm-interrupted" ] || fail "drain did not clear the interrupt marker"
  [ ! -s "$dir/state/.wake-queue" ] || fail "drain did not consume the queued wake"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 after the drain"
  [ "$out" = '{}' ] || fail "cursor shim must allow the stop again after drain, got: $out"
  pass "fm-turnend-guard-cursor: drain clears the marker and restores the silent stop"
}

test_cursor_shim_rearms_on_loop_count_continuation() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-loop-rearm")
  : > "$dir/state/task1.meta"
  install_succeeding_arm_stub "$dir"
  # The wake follow-up turn ends with loop_count>0 and no live watcher: the
  # stop-hook-owned arm must run again, otherwise the primary sits blind until
  # some later turn happens to end with loop_count 0.
  out=$(printf '{"session_id":"cur-session","loop_count":1,"stopHookActive":true,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  pid=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  expect_code 0 "$status" "cursor shim must exit 0 on a loop-count continuation"
  [ "$out" = '{}' ] || fail "cursor shim must emit {} once the continuation arm succeeded, got: $out"
  grep -q '^arm-invoked$' "$dir/state/.arm-invocations" 2>/dev/null \
    || fail "cursor shim must re-arm on a blind loop-count continuation"
  pass "fm-turnend-guard-cursor: a blind loop-count continuation re-arms the stop-hook-owned watcher"
}

test_cursor_shim_wakes_after_actionable_arm_on_continuation() {
  local dir out json status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-loop-actionable")
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  out=$(printf '{"session_id":"cur-session","loop_count":1,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  json=$(printf '%s\n' "$out" | tail -n 1)
  expect_code 0 "$status" "cursor shim must exit 0 after an actionable continuation arm close"
  assert_contains "$json" "firstmate watcher wake" \
    "a continuation whose arm closes actionable must still get the normal wake followup"
  assert_not_contains "$json" "TURN WOULD END BLIND" \
    "continuation wake must not reuse the blind-turn banner"
  assert_not_contains "$json" "bin/fm-watch-arm.sh" \
    "continuation wake must not suggest manual watcher arming"
  pass "fm-turnend-guard-cursor: continuation wakes keep the drain-and-handle followup"
}

cursor_shim_stop() {
  local loop=$1
  shift
  printf '{"session_id":"%s","loop_count":%s,"workspace_roots":["%s"]}' \
    "${CURSOR_FIXTURE_SESSION:-cur-session}" "$loop" "$CURSOR_FIXTURE_DIR" \
    | CURSOR_WORKSPACE_ROOT="$CURSOR_FIXTURE_DIR" "$@" bash "$CURSOR_FIXTURE_DIR/bin/fm-turnend-guard-cursor.sh" 2>&1 \
    | tail -n 1
}

cursor_shim_stop_without_loop_count() {
  printf '{"session_id":"%s","workspace_roots":["%s"]}' \
    "${CURSOR_FIXTURE_SESSION:-cur-session}" "$CURSOR_FIXTURE_DIR" \
    | CURSOR_WORKSPACE_ROOT="$CURSOR_FIXTURE_DIR" "$@" bash "$CURSOR_FIXTURE_DIR/bin/fm-turnend-guard-cursor.sh" 2>&1 \
    | tail -n 1
}

cursor_shim_stop_without_session() {
  local cwd=$1 transcript=$2
  shift 2
  printf '{"cwd":"%s","transcript_path":"%s","workspace_roots":["%s"]}' "$cwd" "$transcript" "$CURSOR_FIXTURE_DIR" \
    | CURSOR_WORKSPACE_ROOT="$CURSOR_FIXTURE_DIR" "$@" bash "$CURSOR_FIXTURE_DIR/bin/fm-turnend-guard-cursor.sh" 2>&1 \
    | tail -n 1
}

cursor_shim_stop_without_identity_parent() {
  local count=$1
  shift
  # shellcheck disable=SC2016 # Variables expand in the inner bash process.
  CURSOR_SHIM_COUNT="$count" CURSOR_WORKSPACE_ROOT="$CURSOR_FIXTURE_DIR" env "$@" bash -c '
    i=0
    while [ "$i" -lt "$CURSOR_SHIM_COUNT" ]; do
      i=$((i + 1))
      printf "{\"workspace_roots\":[\"%s\"]}" "$CURSOR_WORKSPACE_ROOT" \
        | bash "$CURSOR_WORKSPACE_ROOT/bin/fm-turnend-guard-cursor.sh" 2>&1 \
        | tail -n 1
    done
  '
}

cursor_shim_stop_for_conversation() {
  local conversation=$1
  shift
  printf '{"conversation_id":"%s","workspace_roots":["%s"]}' \
    "$conversation" "$CURSOR_FIXTURE_DIR" \
    | CURSOR_WORKSPACE_ROOT="$CURSOR_FIXTURE_DIR" "$@" bash "$CURSOR_FIXTURE_DIR/bin/fm-turnend-guard-cursor.sh" 2>&1 \
    | tail -n 1
}

cursor_shim_stop_with_malformed_loop_count() {
  printf '{"session_id":"%s","loop_count":"malformed","workspace_roots":["%s"]}' \
    "${CURSOR_FIXTURE_SESSION:-cur-session}" "$CURSOR_FIXTURE_DIR" \
    | CURSOR_WORKSPACE_ROOT="$CURSOR_FIXTURE_DIR" "$@" bash "$CURSOR_FIXTURE_DIR/bin/fm-turnend-guard-cursor.sh" 2>&1 \
    | tail -n 1
}

# Each close reports a DIFFERENT typed actionable reason, the ordinary
# supervision case: distinct events handled one after another.
install_varying_actionable_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\\n' >> "$dir/state/.arm-invocations"
n=\$(wc -l < "$dir/state/.arm-invocations")
printf 'signal: task%s.status\\n' "\$n"
exit 0
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_dynamic_stale_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\n' >> "$dir/state/.arm-invocations"
n=\$(wc -l < "$dir/state/.arm-invocations")
printf 'stale: task-window (idle %ss, escalation %s)\n' "\$n" "\$n"
exit 0
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_dynamic_procevent_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\n' >> "$dir/state/.arm-invocations"
n=\$(wc -l < "$dir/state/.arm-invocations")
printf 'check: procevent cursor source-id %s\n' "\$n"
exit 0
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_alternating_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\\n' >> "$dir/state/.arm-invocations"
n=\$(wc -l < "$dir/state/.arm-invocations")
if [ "\$((n % 2))" -eq 1 ]; then
  printf 'signal: task.status\\n'
  exit 0
fi
printf 'registration failure\\n' >&2
exit 1
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_alternating_actionable_arm_stub() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<EOF
#!/usr/bin/env bash
printf 'arm-invoked\\n' >> "$dir/state/.arm-invocations"
n=\$(wc -l < "$dir/state/.arm-invocations")
if [ "\$((n % 2))" -eq 1 ]; then
  printf 'signal: task-a.status\\n'
else
  printf 'signal: task-b.status\\n'
fi
exit 0
EOF
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

test_cursor_shim_bounds_loud_failure_followups() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-fail-budget")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  # Consecutive arm failures keep loud registration/startup guidance, including
  # after the per-failure budget rolls over into the unified chain count.
  for i in 1 2 3 4; do
    out=$(cursor_shim_stop "$i" env)
    assert_contains "$out" "TURN WOULD END BLIND" \
      "arm failure $i of the budget must keep the loud failure followup"
  done
  assert_contains "$out" "repeatedly" \
    "the failure budget rollover must add registration/startup guidance"
  out=$(cursor_shim_stop 5 env)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "the failure budget must keep the banner after rollover instead of silencing it"
  pass "fm-turnend-guard-cursor: repeated arm failures stay loud through budget rollover"
}

test_cursor_shim_wake_chain_does_not_consume_failure_budget() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-wake-then-fail")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  # Healthy actionable wakes advance loop_count on every continuation; they must
  # not consume the arm-failure budget, or a later real arm failure ends the
  # turn blind with no diagnostic.
  for i in 1 2 3; do
    out=$(cursor_shim_stop "$i" env)
    assert_contains "$out" "firstmate watcher wake" \
      "actionable wake $i must keep the drain-and-handle followup"
  done
  install_failing_arm_stub "$dir"
  out=$(cursor_shim_stop 4 env)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "an arm failure after a healthy wake chain must still raise the loud failure followup"
  pass "fm-turnend-guard-cursor: a healthy wake chain never consumes the arm-failure diagnostic"
}

test_cursor_shim_bounds_the_actionable_wake_chain() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-wake-budget")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  # The SAME wake reason re-firing on every armed cycle must not chain forever:
  # normal followups up to the ceiling, one diagnostic at it, then silence.
  for i in 1 2; do
    out=$(cursor_shim_stop "$i" env FM_CURSOR_WAKE_CHAIN_BUDGET=2)
    assert_contains "$out" "firstmate watcher wake" \
      "actionable wake $i under the chain ceiling must still deliver a followup"
    assert_not_contains "$out" "keeps re-firing" \
      "a wake under the ceiling must not carry the repeat diagnostic"
  done
  out=$(cursor_shim_stop 3 env FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "bin/fm-wake-drain.sh" \
    "the ceiling followup must still tell the model to drain the wake"
  assert_contains "$out" "keeps re-firing" \
    "the chain ceiling must deliver a diagnostic rather than silence"
  assert_not_contains "$out" "TURN WOULD END BLIND" \
    "the ceiling diagnostic must not present the blind-turn banner"
  # The ceiling clears the record instead of latching: the next chain starts
  # from a normal drain-and-handle followup rather than silent {} forever.
  out=$(cursor_shim_stop 4 env FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "firstmate watcher wake" \
    "the wake chain must restart normally after the ceiling instead of latching"
  assert_not_contains "$out" "keeps re-firing" \
    "the restarted chain must begin from the normal wake followup"
  pass "fm-turnend-guard-cursor: a re-firing wake reason gets a ceiling diagnostic and then restarts"
}

test_cursor_shim_fresh_turn_resets_the_wake_chain() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-wake-fresh-turn")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  # Drive the same reason to (and past) the ceiling inside one chain.
  for i in 1 2 3; do
    cursor_shim_stop "$i" env FM_CURSOR_WAKE_CHAIN_BUDGET=2 >/dev/null
  done
  # A captain-driven turn ends with loop_count 0: that is a new chain, so the
  # same recurring reason must still get a normal drain-and-handle followup.
  out=$(cursor_shim_stop 0 env FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "firstmate watcher wake" \
    "a non-continuation stop must start a fresh chain, not inherit an exhausted one"
  assert_not_contains "$out" "keeps re-firing" \
    "a non-continuation stop must reset the repeat count"
  pass "fm-turnend-guard-cursor: a non-continuation stop resets the wake chain"
}

test_cursor_shim_hard_bound_ends_a_runaway_chain() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-hard-bound")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_alternating_arm_stub "$dir"
  # One real arm sequence alternates actionable and failed closes. Distinct
  # progress does not consume the bound, but the failures eventually reach the
  # unified ceiling and keep a diagnostic instead of emitting {}.
  for i in 1 2 3 4 5; do
    out=$(cursor_shim_stop_without_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=2 FM_CURSOR_WAKE_CHAIN_BUDGET=3)
    [ "$out" != '{}' ] || fail "alternating arm sequence emitted {} before its diagnostic ceiling"
  done
  out=$(cursor_shim_stop_without_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=2 FM_CURSOR_WAKE_CHAIN_BUDGET=3)
  [ "$out" != '{}' ] || fail "alternating arm sequence emitted {} at its diagnostic ceiling"
  assert_contains "$out" "bounded chain" \
    "alternating actionable/failed arms must reach the unified diagnostic ceiling"
  assert_contains "$out" "TURN WOULD END BLIND" \
    "alternating arm ceiling must retain loud failure guidance"
  pass "fm-turnend-guard-cursor: alternating arm outcomes share one persistent hard bound"
}

# One re-fire path, three wake shapes. Each shape stays under its ceiling while
# the chain is still progressing, reaches its diagnostic when the re-fires
# exhaust the bound, and clears the record rather than latching. <ceiling-text>
# names which ceiling that shape is expected to reach: a previously-seen reason
# re-firing non-consecutively reaches the unified TOTAL ceiling, while a reason
# whose only variation is a changing detail canonicalizes to one key and
# reaches the per-reason repeat ceiling.
run_cursor_shim_wake_refire_case() {  # <slug> <arm-stub-installer> <turns-under-ceiling> <ceiling-text> <description>
  local slug=$1 stub=$2 under=$3 ceiling_text=$4 desc=$5
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-$slug")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  "$stub" "$dir"
  i=1
  while [ "$i" -le "$under" ]; do
    out=$(cursor_shim_stop "$i" env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
    assert_not_contains "$out" "$ceiling_text" \
      "$desc: progressing wake $i must not reach the ceiling"
    i=$((i + 1))
  done
  out=$(cursor_shim_stop "$i" env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "$ceiling_text" \
    "$desc: the re-fires must reach the ceiling diagnostic"
  out=$(cursor_shim_stop "$((i + 1))" env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "firstmate watcher wake" \
    "$desc: the next chain must restart after the ceiling"
  assert_not_contains "$out" "$ceiling_text" \
    "$desc: the cleared ceiling must not latch"
  pass "fm-turnend-guard-cursor: $desc"
}

test_cursor_shim_bounds_wake_refires() {
  run_cursor_shim_wake_refire_case wake-refires \
    install_alternating_actionable_arm_stub 4 "diagnostic ceiling" \
    "non-consecutive wake re-fires share the persistent bound"
  run_cursor_shim_wake_refire_case dynamic-wake-refires \
    install_dynamic_stale_arm_stub 2 "keeps re-firing" \
    "dynamic wake diagnostics share a canonical bound key"
  run_cursor_shim_wake_refire_case procevent-refires \
    install_dynamic_procevent_arm_stub 2 "keeps re-firing" \
    "process-event sequence details share a canonical bound key"
}

test_cursor_shim_persists_bound_without_valid_loop_count() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-invalid-loop-count")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  out=$(cursor_shim_stop_without_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "an absent loop_count must use persistent failure state"
  out=$(cursor_shim_stop_with_malformed_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "bounded chain" \
    "a malformed loop_count must not reset the persistent hard bound"
  assert_contains "$out" "TURN WOULD END BLIND" \
    "the malformed loop_count ceiling must stay loud on arm failure"
  out=$(cursor_shim_stop_without_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "the next invalid-loop chain must start normally after the ceiling clears state"
  assert_not_contains "$out" "bounded chain" \
    "the next invalid-loop chain must not inherit the cleared ceiling"
  pass "fm-turnend-guard-cursor: absent and malformed loop_count preserve bounded state"
}

test_cursor_shim_distinct_wakes_do_not_hit_the_chain_ceiling() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-wake-distinct")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_varying_actionable_arm_stub "$dir"
  # Ordinary supervision: every cycle closes on a different actionable event.
  # These are progress, not a stuck reason, so the ceiling must never fire and
  # leave the primary with an undrained wake and no watcher.
  for i in 1 2 3 4; do
    out=$(cursor_shim_stop "$i" env FM_CURSOR_WAKE_CHAIN_BUDGET=2)
    assert_contains "$out" "firstmate watcher wake" \
      "distinct actionable wake $i must keep delivering a normal drain-and-handle followup"
    assert_not_contains "$out" "keeps re-firing" \
      "distinct actionable wakes must not accumulate toward the repeat ceiling"
  done
  pass "fm-turnend-guard-cursor: distinct wake reasons reset the chain instead of exhausting it"
}

test_cursor_shim_failure_budget_is_session_scoped() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-session-scope")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  out=$(cursor_shim_stop 0 env FM_CURSOR_TURNEND_BLOCK_BUDGET=1)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "the first arm failure of a session must raise the loud failure followup"
  # A fresh session must not inherit the previous session's exhausted budget:
  # a hooks.json registration failure is most likely on a session's first stop.
  CURSOR_FIXTURE_SESSION=cur-session-2
  out=$(cursor_shim_stop 1 env FM_CURSOR_TURNEND_BLOCK_BUDGET=1)
  CURSOR_FIXTURE_SESSION=
  assert_contains "$out" "TURN WOULD END BLIND" \
    "a new session must reset the failure budget rather than inherit a stale count"
  pass "fm-turnend-guard-cursor: the continuation budgets are session-scoped"
}

test_cursor_shim_prefers_conversation_id_for_persistent_scope() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-conversation-scope")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  out=$(cursor_shim_stop_for_conversation conversation-a env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "firstmate watcher wake" \
    "the first conversation wake must stay normal"
  out=$(cursor_shim_stop_for_conversation conversation-a env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "firstmate watcher wake" \
    "a repeated wake in one conversation must stay below its ceiling"
  out=$(cursor_shim_stop_for_conversation conversation-b env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "firstmate watcher wake" \
    "a separate conversation must start a fresh persistent chain"
  assert_not_contains "$out" "diagnostic ceiling" \
    "a separate conversation must not inherit another conversation's bound"
  out=$(cursor_shim_stop_for_conversation conversation-a env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=2)
  assert_contains "$out" "keeps re-firing" \
    "a separate conversation must not clear the first conversation's persistent chain"
  pass "fm-turnend-guard-cursor: conversation_id isolates persistent chain state"
}

test_cursor_shim_fallback_session_scope() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-fallback-scope")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  out=$(cursor_shim_stop_without_session same-project transcript-a env -u CURSOR_CONVERSATION_ID FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "firstmate watcher wake" \
    "a payload without a session id must still deliver its first wake"
  out=$(cursor_shim_stop_without_session same-project transcript-b env -u CURSOR_CONVERSATION_ID FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "firstmate watcher wake" \
    "a separate unidentified session must start a fresh wake chain"
  out=$(cursor_shim_stop_without_session same-project transcript-a env -u CURSOR_CONVERSATION_ID FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "keeps re-firing" \
    "unidentified sessions must not share or clear each other's wake bounds"
  pass "fm-turnend-guard-cursor: unidentified payloads keep isolated persistent chains"
}

test_cursor_shim_fallback_without_identity_is_process_scoped() {
  local dir out first second
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-process-scope")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  out=$(cursor_shim_stop_without_identity_parent 2 env -u CURSOR_CONVERSATION_ID FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  first=$(printf '%s\n' "$out" | sed -n '1p')
  second=$(printf '%s\n' "$out" | sed -n '2p')
  assert_contains "$first" "firstmate watcher wake" \
    "an identity-free payload must deliver its first wake"
  assert_contains "$second" "keeps re-firing" \
    "repeated identity-free wakes in one parent session must remain bounded"
  out=$(cursor_shim_stop_without_identity_parent 1 env -u CURSOR_CONVERSATION_ID FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "firstmate watcher wake" \
    "a separate identity-free parent session must start a fresh chain"
  assert_not_contains "$out" "keeps re-firing" \
    "separate identity-free parent sessions must not inherit another chain"
  pass "fm-turnend-guard-cursor: identity-free fallback chains are parent-session scoped"
}

test_cursor_shim_parent_starttime_scopes_identity_free_chain() {
  local dir fakebin ps_count real_ps out first second
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-parent-starttime")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  fakebin=$(fm_fakebin "$TMP_ROOT/cursor-shim-parent-starttime-bin")
  ps_count="$dir/state/.fake-ps-count"
  real_ps=$(command -v ps)
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(/bin/cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  printf 'synthetic-start-%s\n' "$count"
  exit 0
fi
exec "$REAL_PS" "$@"
SH
  chmod +x "$fakebin/ps"
  out=$(cursor_shim_stop_without_identity_parent 2 env \
    PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" \
    FM_FAKE_PS_COUNT="$ps_count" REAL_PS="$real_ps" \
    FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  first=$(printf '%s\n' "$out" | sed -n '1p')
  second=$(printf '%s\n' "$out" | sed -n '2p')
  assert_contains "$first" "firstmate watcher wake" \
    "the first identity-free parent observation must deliver its wake"
  assert_contains "$second" "firstmate watcher wake" \
    "a changed parent starttime must start a fresh chain"
  assert_not_contains "$second" "keeps re-firing" \
    "a reused parent pid with a new starttime must not inherit its old chain"
  pass "fm-turnend-guard-cursor: parent starttime prevents pid-reuse chain inheritance"
}

test_cursor_shim_without_parent_identity_uses_payload_fallback() {
  local dir fakebin out first second
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-no-parent-identity")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_actionable_arm_stub "$dir"
  fakebin=$(fm_fakebin "$TMP_ROOT/cursor-shim-no-parent-identity-bin")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(cursor_shim_stop_without_identity_parent 2 env \
    PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" \
    FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  first=$(printf '%s\n' "$out" | sed -n '1p')
  second=$(printf '%s\n' "$out" | sed -n '2p')
  assert_contains "$first" "firstmate watcher wake" \
    "missing parent identity must still start a bounded payload-keyed chain"
  assert_contains "$second" "keeps re-firing" \
    "missing parent identity must persist repeat bounds without a reusable pid"
  pass "fm-turnend-guard-cursor: missing parent identity uses bounded payload fallback"
}

test_cursor_shim_extreme_loop_count_stays_bounded_without_state() {
  local dir fakebin out
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-extreme-loop-count")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  fakebin=$(fm_fakebin "$TMP_ROOT/cursor-shim-extreme-loop-count-bin")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mv"
  out=$(cursor_shim_stop 9223372036854775807 env \
    PATH="$fakebin:$PATH" FM_CURSOR_TURNEND_BLOCK_BUDGET=1 \
    FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  [ "$out" != '{}' ] || fail "an extreme loop_count must not allow an unbounded blind chain"
  assert_contains "$out" "bounded chain" \
    "an extreme loop_count must saturate the diagnostic ceiling when state cannot persist"
  pass "fm-turnend-guard-cursor: extreme loop_count fallback stays bounded"
}

test_cursor_shim_falls_back_to_loop_count_without_writable_state() {
  local dir out
  if [ "$(id -u)" -eq 0 ]; then
    pass "fm-turnend-guard-cursor: loop_count fallback skipped (root ignores directory permissions)"
    return 0
  fi
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-ro-state")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  chmod 500 "$dir/state"
  # The chain record cannot be persisted, so a positive loop_count carries the
  # fallback bound; absent loop_count fails closed with a loud diagnostic.
  out=$(cursor_shim_stop 0 env FM_CURSOR_TURNEND_BLOCK_BUDGET=3)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "an unpersisted first failure must still raise the loud failure followup"
  out=$(cursor_shim_stop 8 env FM_CURSOR_TURNEND_BLOCK_BUDGET=3)
  chmod 700 "$dir/state"
  [ "$out" != '{}' ] || fail "cursor shim must keep a diagnostic when the chain record cannot persist"
  assert_contains "$out" "TURN WOULD END BLIND" \
    "the payload fallback ceiling must retain loud failure guidance"
  pass "fm-turnend-guard-cursor: an unwritable state dir degrades to the payload loop_count bound"
}

test_cursor_shim_rejects_fractional_loop_count() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-fractional-loop-count")
  CURSOR_FIXTURE_DIR=$dir
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  out=$(cursor_shim_stop_without_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "TURN WOULD END BLIND" \
    "the first arm failure must establish persistent state before the fractional input"
  out=$(cursor_shim_stop 0.5 env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_contains "$out" "bounded chain" \
    "a fractional loop_count must not clear persistent bound state"
  out=$(cursor_shim_stop_without_loop_count env FM_CURSOR_TURNEND_BLOCK_BUDGET=1 FM_CURSOR_WAKE_CHAIN_BUDGET=1)
  assert_not_contains "$out" "bounded chain" \
    "the fractional-input ceiling must clear state for the next chain"
  pass "fm-turnend-guard-cursor: fractional loop_count stays malformed"
}

test_cursor_shim_arm_sources_x_mode_cadence() {
  local dir out status cadence
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-xmode")
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  mkdir -p "$dir/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$dir/config/x-mode.env"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 on a still-blind turn with X mode config"
  cadence=$(cat "$dir/state/.arm-cadence" 2>/dev/null || true)
  [ "$cadence" = 30 ] || fail "arm wrapper must inherit the X-mode cadence from config/x-mode.env, got: $cadence"
  pass "fm-turnend-guard-cursor: arm inherits the X-mode 30s cadence from config/x-mode.env"
}

test_cursor_shim_arm_defaults_cadence_without_x_mode() {
  local dir out status cadence
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-noxmode")
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  out=$(printf '{"session_id":"cur-session","loop_count":0,"workspace_roots":["%s"]}' "$dir" \
    | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must exit 0 on a still-blind turn without X mode config"
  cadence=$(cat "$dir/state/.arm-cadence" 2>/dev/null || true)
  [ -z "$cadence" ] || fail "arm wrapper must keep the default cadence without config/x-mode.env, got: $cadence"
  pass "fm-turnend-guard-cursor: arm leaves the default cadence when config/x-mode.env is absent"
}

test_cursor_shim_missing_payload_allows() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-empty")
  out=$(printf '' | CURSOR_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-cursor.sh" 2>&1); status=$?
  expect_code 0 "$status" "cursor shim must allow an empty payload"
  [ -z "$out" ] || fail "cursor shim produced output on empty payload: $out"
  pass "fm-turnend-guard-cursor: empty or unreadable payloads conservatively allow"
}

test_cursor_hooks_json_is_registered() {
  local hooks stop_command pretool_command
  hooks="$ROOT/.cursor/hooks.json"
  # shellcheck disable=SC2016 # Variables expand in the generated hook command.
  stop_command='[ -n "${CURSOR_PROJECT_DIR:-}" ] && exec "${CURSOR_PROJECT_DIR:-}/bin/fm-turnend-guard-cursor.sh"; exit 0'
  # shellcheck disable=SC2016 # Variables expand in the generated hook command.
  pretool_command='[ -n "${CURSOR_PROJECT_DIR:-}" ] && exec "${CURSOR_PROJECT_DIR:-}/bin/fm-arm-pretool-check.sh" --cursor; exit 0'
  [ -f "$hooks" ] || fail "tracked .cursor/hooks.json is missing"
  jq -e '.version == 1' "$hooks" >/dev/null || fail "cursor hooks.json must carry the load-bearing version key"
  jq -e '.hooks.stop | type == "array" and length > 0' "$hooks" >/dev/null \
    || fail "cursor hooks.json must register a stop hook"
  jq -e '.hooks.preToolUse | type == "array" and length > 0' "$hooks" >/dev/null \
    || fail "cursor hooks.json must register a preToolUse hook"
  jq -e --arg required "$stop_command" '
    .hooks.stop | any(.[];
      type == "object"
      and .command == $required
      and (.timeout | type == "number" and . >= 600)
      and has("loop_limit") and .loop_limit == null
    )
  ' "$hooks" >/dev/null || fail "cursor stop hook registration is missing its required command"
  jq -e --arg required "$pretool_command" '
    .hooks.preToolUse | any(.[];
      type == "object"
      and .matcher == "Shell"
      and .command == $required
      and (.timeout | type == "number" and . > 0)
    )
  ' "$hooks" >/dev/null || fail "cursor preToolUse registration is missing its required command"
  pass "fm-turnend-guard-cursor: tracked .cursor/hooks.json registers the shim, the seatbelt, and the load-bearing version key"
}

test_cursor_pretool_hook_executes_seatbelt() {
  local command payload out status pretool_command
  # shellcheck disable=SC2016 # Variables expand in the generated hook command.
  pretool_command='[ -n "${CURSOR_PROJECT_DIR:-}" ] && exec "${CURSOR_PROJECT_DIR:-}/bin/fm-arm-pretool-check.sh" --cursor; exit 0'
  command=$(jq -r --arg required "$pretool_command" '[.hooks.preToolUse[] | select(.matcher == "Shell" and .command == $required)] | .[0].command // empty' "$ROOT/.cursor/hooks.json")
  [ -n "$command" ] || fail "required Cursor preToolUse command is missing from .cursor/hooks.json"
  payload=$(jq -cn '{tool_name:"Shell",tool_input:{command:"bin/fm-watch-arm.sh &"}}')
  out=$(printf '%s' "$payload" | CURSOR_PROJECT_DIR="$ROOT" bash -c "$command" 2>&1); status=$?
  expect_code 2 "$status" "cursor preToolUse hook must execute the seatbelt"
  assert_contains "$out" '"permission":"deny"' \
    "cursor preToolUse hook must return the deny permission object"
  pass "fm-turnend-guard-cursor: tracked preToolUse hook executes the Cursor seatbelt"
}

test_cursor_shim_anchor_resolves_via_cursor_project_dir() {
  local command dir payload out status stop_command
  # shellcheck disable=SC2016 # Variables expand in the generated hook command.
  stop_command='[ -n "${CURSOR_PROJECT_DIR:-}" ] && exec "${CURSOR_PROJECT_DIR:-}/bin/fm-turnend-guard-cursor.sh"; exit 0'
  command=$(jq -r --arg required "$stop_command" '[.hooks.stop[] | select(.command == $required)] | .[0].command // empty' "$ROOT/.cursor/hooks.json")
  [ -n "$command" ] || fail "stop hook command is missing from .cursor/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/cursor-shim-anchor")
  : > "$dir/state/task1.meta"
  install_failing_arm_stub "$dir"
  # The hook command anchors through CURSOR_PROJECT_DIR (verified live:
  # cursor sets it to the project root for hook commands). Executing it with
  # that env var must run the real shim against this scenario dir.
  payload=$(jq -cn --arg dir "$dir" '{session_id:"cur-session",loop_count:0,workspace_roots:[$dir]}')
  out=$(printf '%s' "$payload" | CURSOR_PROJECT_DIR="$dir" bash -c "$command" 2>&1); status=$?
  expect_code 0 "$status" "cursor hook command anchored through CURSOR_PROJECT_DIR must run"
  case "$out" in
    *'TURN WOULD END BLIND'*) : ;;
    *) fail "cursor hook command did not reach the translating shim's blocked banner, got: $out" ;;
  esac
  pass "fm-turnend-guard-cursor: the tracked hook command anchors through CURSOR_PROJECT_DIR"
}

