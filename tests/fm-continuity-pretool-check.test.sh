#!/usr/bin/env bash
# Behavior tests for Claude's narrowly scoped watcher-continuity PreToolUse gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-continuity-pretool-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-continuity-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_command() {
  local command=$1 rc=0
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 command=$2 rc=0
  run_command "$command" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 command=$2 blocked=$3 expected=${4:-} rc=0 actual
  run_command "$command" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  [ -n "$expected" ] || expected="[watcher-continuity] tasks are in flight and no live watcher holds this home lock; drain wakes with bin/fm-wake-drain.sh, use fail-closed bin/fm-teardown.sh for completed tasks when needed, then end the turn so the Stop-owned auto-arm re-establishes the watcher; if the Stop auto-arm itself failed, re-arm manually with bin/fm-watch-arm.sh as a tracked Claude background task (blocked: $blocked)"
  actual=$(jq -r '.systemMessage' "$ERR")
  [ "$actual" = "$expected" ] || fail "$label recovery guidance changed: $actual"
}

test_gate_scope_and_recovery_exceptions() {
  expect_allow "idle fleet command" 'bin/fm-crew-state.sh task'
  printf 'project=fixture\n' > "$STATE/task.meta"

  expect_allow "ordinary shell command" 'git status --short'
  expect_allow "fleet-script text as data" "rg -n 'bin/fm-send.sh' docs"
  expect_allow "wake drain recovery" 'bin/fm-wake-drain.sh'
  expect_allow "watch arm recovery" 'bin/fm-watch-arm.sh'
  expect_allow "drain then arm recovery" 'bin/fm-wake-drain.sh; bin/fm-watch-arm.sh'
  expect_allow "fail-closed teardown recovery" 'bin/fm-teardown.sh task'
  unsafe_teardown_reason='[watcher-continuity] tasks are in flight and no live watcher holds this home lock; during recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: fm-teardown.sh)'
  expect_deny "forced teardown is not recovery" 'bin/fm-teardown.sh task --force' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "nested forced teardown is not recovery" "bash -lc 'bin/fm-teardown.sh task --force'" 'fm-teardown.sh' "$unsafe_teardown_reason"
  # shellcheck disable=SC2016  # single quotes are deliberate: "$TEARDOWN_MODE" is literal test data (an unsafe shell-expanded arg the gate must deny), not an expansion here
  expect_deny "dynamic teardown mode is not recovery" 'bin/fm-teardown.sh task "$TEARDOWN_MODE"' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "unrelated fleet command" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  expect_deny "recovery bundled with unrelated fleet command" 'bin/fm-wake-drain.sh; bin/fm-send.sh task hi' 'fm-send.sh'
  expect_deny "literal nested fleet command" "bash -lc 'bin/fm-bootstrap.sh'" 'fm-bootstrap.sh'
  pass "continuity gate allows recovery and ordinary commands but denies only other fleet execution"
}

test_live_lock_allows_fleet_command_even_with_stale_beacon() {
  local holder identity rc=0
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify live continuity fixture"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
  touch -t 200001010000 "$STATE/.last-watcher-beat"

  run_command 'bin/fm-crew-state.sh task' || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "identity-matched live lock must allow fleet command even when its beacon is stale"
  [ ! -s "$ERR" ] || fail "live-lock allow wrote stderr: $(cat "$ERR")"
  pass "continuity gate classifies the lock by live PID identity rather than beacon age"
}

cycle_row() {  # <watcher-pid> <origin> <started-at> <ended-at> <reason> <identity>
  printf 'arm_pid=1\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=0\tsignal=none\treason=%s\tbeacon_age=1\tlock_before=pid:%s|identity:%s\tlock_after=pid:none|identity:none\tsuccessor=none\n' \
    "$1" "$2" "$3" "$4" "$5" "$1" "$6" >> "$STATE/.watch-cycle-exits.log"
}

test_delivered_wake_gap_is_allowed_and_unexplained_absence_is_not() {
  local now
  now=$(date +%s)
  rm -rf "$STATE/.watch.lock"
  rm -f "$STATE/.watch-cycle-exits.log"
  [ -e "$STATE/task.meta" ] || printf 'project=fixture\n' > "$STATE/task.meta"

  expect_deny "no lifecycle record at all" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'

  cycle_row 4242 started "$((now - 20))" "$((now - 10))" actionable-signal owner-a
  expect_allow "post-wake gap after a delivered wake" 'bin/fm-crew-state.sh task'
  expect_allow "post-wake gap still permits a merge" 'bin/fm-pr-merge.sh task'
  expect_allow "post-wake gap still permits a dispatch" 'bin/fm-spawn.sh next'

  cycle_row 4242 attached "$((now - 20))" "$((now - 5))" attached-cycle-ended owner-a
  expect_allow "attached observer of the delivered cycle" 'bin/fm-crew-state.sh task'

  # Append order is the monotonic cycle cursor. A later owner failure supersedes
  # the wake even if its wall clock moved backwards.
  cycle_row 9191 started "$((now - 50))" "$((now - 40))" unexpected-clean-exit owner-b
  expect_deny "later owner cycle closed unexplained" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'

  rm -f "$STATE/.watch-cycle-exits.log"
  cycle_row 4242 started "$((now - 3610))" "$((now - 3600))" actionable-heartbeat owner-old
  expect_deny "delivered wake older than the gap window" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'

  rm -f "$STATE/.watch-cycle-exits.log"
  cycle_row 4242 started "$((now - 40))" "$((now - 30))" actionable-heartbeat owner-short
  expect_allow "delivered wake inside the default window" 'bin/fm-crew-state.sh task'
  export FM_CONTINUITY_GAP_GRACE=5
  expect_deny "same record outside a shortened window" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  unset FM_CONTINUITY_GAP_GRACE

  printf 'arm_pid=1\twatcher_pid=4242\torigin=started\tstarted_at=%s\tended_at=%s\texit_code=0\tsignal=none\treason=actionable-signal' \
    "$((now - 20))" "$((now - 10))" > "$STATE/.watch-cycle-exits.log"
  expect_deny "truncated delivered-wake row" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'

  rm -f "$STATE/.watch-cycle-exits.log"
  pass "continuity gate allows only the bounded recorded post-wake gap"
}

test_child_worktree_and_malformed_input_fail_open() {
  local child="$TMP_ROOT/child" rc=0
  rm -rf "$STATE/.watch.lock"
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --command 'bin/fm-send.sh task hi' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "linked child worktree must be out of continuity-gate scope"

  expect_allow "malformed dynamic shell" "bin/fm-send.sh 'unterminated"
  printf '%s' '{not-json' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed Claude transport must fail open"
  pass "continuity gate excludes child worktrees and fails open on opaque input"
}

test_claude_hook_registration_preserves_stop_backstop() {
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
      | any(contains("fm-continuity-pretool-check.sh"))
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude settings omit the continuity PreToolUse hook"
  jq -e '
    .hooks.Stop == [{"hooks":[
      {"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"},
      {"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh","asyncRewake":true,"timeout":28800}
    ]}]
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude Stop registration changed: the --claude guard and the asyncRewake auto-arm with an explicit multi-hour timeout must both stay registered"
  pass "Claude wires the continuity gate, the --claude Stop backstop, and the Stop-owned auto-arm registration"
}

test_gate_scope_and_recovery_exceptions
test_live_lock_allows_fleet_command_even_with_stale_beacon
test_delivered_wake_gap_is_allowed_and_unexplained_absence_is_not
test_child_worktree_and_malformed_input_fail_open
test_claude_hook_registration_preserves_stop_backstop
