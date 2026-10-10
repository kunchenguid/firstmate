#!/usr/bin/env bash
# Behavior tests for Antigravity CLI (agy) as a firstmate PRIMARY
# (docs/turnend-guard.md, docs/watcher-continuity.md,
# docs/verification/agy.md).
#
# Hermetic tests over temporary directories with real processes:
#   HOST GUARD  - bin/fm-hook-host-lib.sh, standing down on a foreign-host
#                 payload (such as Cursor).
#   PARK        - bin/fm-turnend-guard-agy.sh, the stop-hook park: its
#                 continue/allow decision object output, double loop bound,
#                 bounded repair nag, and post-claim supersession contract.
#   GUARD       - bin/fm-turnend-guard.sh --agy, the shared turn-end guard.
#
# The park runs as a child of a fake harness executable named agy whose pid
# holds the fixture home's session lock, so the real ancestry path in
# bin/fm-session-lock-lib.sh is exercised rather than stubbed.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake agy process"
cat > "$TMP_ROOT/fake-agy.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
"$CC_BIN" -o "$FAKEBIN/agy" "$TMP_ROOT/fake-agy.c" \
  || fail "could not build the fake agy process"
FAKE_AGY="$FAKEBIN/agy"

AGY_PAYLOAD='{"conversationId":"conv-agy-1","executionNum":1,"terminationReason":"model_stop","fullyIdle":true,"workspacePaths":["/path"]}'
CURSOR_PAYLOAD='{"session_id":"sess-cursor","cursor_version":"2026.08.11-e8db854"}'

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard-agy.sh fm-turnend-guard.sh fm-hook-host-lib.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
           fm-path-lib.sh fm-classify-lib.sh fm-timeout-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-gate-refuse-lib.sh fm-supervision-engine-lib.sh; do
    [ -f "$ROOT/bin/$f" ] && cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir"/bin/*.sh
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

write_arm_fixture() {  # <dir> <kind>
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: task-win needs attention\n'
exit 0
SH
      ;;
    healthy)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 1s)\n' "$$"
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    switchable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
if [ -e "$FM_HOME/state/arm-fast" ]; then
  printf 'stale: task-fast wake\n'
  exit 0
fi
sleep 30
printf 'stale: task-late wake\n'
exit 0
SH
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

PARK_CHILD='
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-turnend-guard-agy.sh"
'

run_park() {  # <dir> [exec_num] [ceiling] [payload_override]
  local dir=$1 exec_num=${2:-1} ceiling=${3:-} payload_override=${4:-} payload
  if [ -n "$payload_override" ]; then
    payload=$payload_override
  else
    payload=$(printf '{"conversationId":"conv-agy-1","executionNum":%s,"terminationReason":"model_stop","fullyIdle":true}' "$exec_num")
  fi
  if [ -n "$ceiling" ]; then
    printf '%s' "$payload" | env FM_HOME="$dir" FM_AGY_PARK_POLL=1 \
      FM_AGY_TURNEND_LOOP_CEILING="$ceiling" "$FAKE_AGY" -c "$PARK_CHILD" 2>/dev/null
  else
    printf '%s' "$payload" | env FM_HOME="$dir" FM_AGY_PARK_POLL=1 \
      "$FAKE_AGY" -c "$PARK_CHILD" 2>/dev/null
  fi
}

decision_of() {  # <json>
  printf '%s' "$1" | jq -r '.decision // empty' 2>/dev/null
}

reason_of() {  # <json>
  printf '%s' "$1" | jq -r '.reason // empty' 2>/dev/null
}

kind_of_reason() {  # <json>
  local reason
  reason=$(reason_of "$1")
  [ -n "$reason" ] || return 1
  printf '%s' "$reason" | "$ROOT/bin/fm-operational-input.sh" kind
}

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

test_turnend_guard_supports_agy_flag() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/guard-agy")
  : > "$dir/state/task1.meta"
  out=$(printf '%s' "$AGY_PAYLOAD" | bash "$dir/bin/fm-turnend-guard.sh" --agy 2>&1); status=$?
  expect_code 2 "$status" "--agy must reach the shared block decision when supervision is off"
  case "$out" in *'TURN WOULD END BLIND'*) ;; *) fail "expected shared banner, got: $out" ;; esac

  rm -f "$dir/state/task1.meta"
  out=$(printf '%s' "$AGY_PAYLOAD" | bash "$dir/bin/fm-turnend-guard.sh" --agy 2>&1); status=$?
  expect_code 0 "$status" "--agy must exit 0 when supervision is not needed"
  pass "fm-turnend-guard: supports --agy and reflects supervision need"
}

test_park_inert_when_not_primary() {
  local dir child out decision
  dir=$(make_primary_dir "$TMP_ROOT/scope-parent")
  child="$dir/worktrees/task1"
  git -C "$dir" worktree add -q -b task1-branch "$child"
  mkdir -p "$child/state" "$child/bin"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  : > "$child/state/task1.meta"
  write_arm_fixture "$child" actionable

  out=$(run_park "$child")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "task worktree must allow stop, got: $out"
  [ ! -e "$child/state/arm-ran" ] || fail "arm should not run in task worktree"
  pass "fm-turnend-guard-agy: inert in child task worktrees"
}

test_park_inert_on_foreign_host() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/host-foreign")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable

  out=$(run_park "$dir" 1 "" "$CURSOR_PAYLOAD")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "foreign host must allow stop, got: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "arm should not run on foreign host payload"
  pass "fm-turnend-guard-agy: inert on foreign host payload"
}

test_park_inert_on_non_model_stop() {
  local dir payload out decision
  dir=$(make_primary_dir "$TMP_ROOT/non-model-stop")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable

  payload='{"conversationId":"conv-1","executionNum":1,"terminationReason":"error"}'
  out=$(run_park "$dir" 1 "" "$payload")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "error termination must allow stop, got: $out"

  payload='{"conversationId":"conv-1","executionNum":1,"terminationReason":"max_steps_exceeded"}'
  out=$(run_park "$dir" 1 "" "$payload")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "max_steps_exceeded termination must allow stop, got: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "arm should not run on non-model-stop"

  # NO_TOOL_CALL is Antigravity CLI's live enum for text completions and must park.
  rm -f "$dir/state/arm-ran"
  payload='{"conversationId":"conv-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  out=$(run_park "$dir" 1 "" "$payload")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "NO_TOOL_CALL must park and emit continue, got: $out"
  [ -e "$dir/state/arm-ran" ] || fail "arm should run on NO_TOOL_CALL"

  pass "fm-turnend-guard-agy: inert on error/max_steps, active on NO_TOOL_CALL"
}

test_park_inert_in_away_mode() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/away-mode")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable

  out=$(run_park "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "away mode must allow stop, got: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "arm should not run in away mode"
  pass "fm-turnend-guard-agy: inert in away mode"
}

test_park_inert_when_supervision_not_needed() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/idle-home")
  write_arm_fixture "$dir" actionable

  out=$(run_park "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "idle home must allow stop, got: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "arm should not run when idle"
  pass "fm-turnend-guard-agy: inert when no supervision needed"
}

test_park_delivers_actionable_wake() {
  local dir out decision reason kind
  dir=$(make_primary_dir "$TMP_ROOT/actionable-wake")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable

  out=$(run_park "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "actionable wake must return decision continue, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'stale: task-win needs attention'*) ;;
    *) fail "expected wake content in reason, got: $reason" ;;
  esac
  case "$reason" in
    *'bin/fm-wake-drain.sh'*) ;;
    *) fail "expected wake drain instruction in reason, got: $reason" ;;
  esac
  kind=$(kind_of_reason "$out")
  [ "$kind" = "watcher" ] || fail "expected operational kind watcher, got: $kind"
  pass "fm-turnend-guard-agy: delivers actionable wake as continue decision"
}

test_park_delivers_repair_followup_and_bounds_budget() {
  local dir out decision reason i
  dir=$(make_primary_dir "$TMP_ROOT/failed-park")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed

  out=$(run_park "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "failed park must return continue nag 1, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'TURN WOULD END BLIND'*) ;;
    *) fail "expected repair banner in reason, got: $reason" ;;
  esac

  # Exhaust the BLOCK_BUDGET (3 blocks).
  for i in 2 3; do
    out=$(run_park "$dir")
    decision=$(decision_of "$out")
    [ "$decision" = "continue" ] || fail "failed park must continue through budget ($i), got: $out"
  done

  # 4th attempt must fail open to avoid trapping the user.
  out=$(run_park "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "budget exhaustion must allow stop (fail open), got: $out"
  pass "fm-turnend-guard-agy: repair followup bounds consecutive failures"
}

test_park_enforces_loop_ceiling() {
  local dir out decision reason
  dir=$(make_primary_dir "$TMP_ROOT/loop-ceiling")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable

  out=$(run_park "$dir" 180 180)
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "loop ceiling hit must return continue, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'FIRSTMATE SUPERVISION CEILING REACHED'*) ;;
    *) fail "expected ceiling notice in reason, got: $reason" ;;
  esac

  # Beyond ceiling stops emitting continuations.
  out=$(run_park "$dir" 181 180)
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "past ceiling must allow stop, got: $out"
  pass "fm-turnend-guard-agy: enforces loop ceiling"
}

test_park_supersession_stands_down() {
  local dir p1_out p2_out p1_pid d1 d2
  dir=$(make_primary_dir "$TMP_ROOT/supersession")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable

  # Start first park running in background.
  run_park "$dir" 1 > "$TMP_ROOT/p1.out" 2>/dev/null &
  p1_pid=$!
  sleep 1

  # Trigger fast wake for second park.
  : > "$dir/state/arm-fast"
  p2_out=$(run_park "$dir" 2)
  d2=$(decision_of "$p2_out")
  [ "$d2" = "continue" ] || fail "second park must win and deliver wake, got: $p2_out"

  # Wait for first park to finish.
  wait "$p1_pid" 2>/dev/null || true
  p1_out=$(cat "$TMP_ROOT/p1.out" 2>/dev/null || true)
  d1=$(decision_of "$p1_out")
  [ "$d1" = "allow" ] || fail "superseded first park must stand down with allow, got: $p1_out"
  pass "fm-turnend-guard-agy: superseded park stands down without emitting duplicate wake"
}

test_hooks_json_commands_execute_cleanly() {
  local stop_cmd pretool_cmd out rc=0
  stop_cmd=$(jq -r '."supervision-guard".Stop[0].command' "$ROOT/.agents/hooks.json")
  pretool_cmd=$(jq -r '."subagent-guard".PreToolUse[0].hooks[0].command' "$ROOT/.agents/hooks.json")

  [ -n "$stop_cmd" ] && [ "$stop_cmd" != "null" ] || fail "hooks.json must declare Stop command"
  [ -n "$pretool_cmd" ] && [ "$pretool_cmd" != "null" ] || fail "hooks.json must declare PreToolUse command"

  # Stop hook with non-model stop should allow and exit 0 without failing
  out=$(printf '{"conversationId":"test","executionNum":1,"terminationReason":"error"}' | (cd "$ROOT" && eval "$stop_cmd")) || rc=$?
  [ "$rc" -eq 0 ] || fail "Stop command must exit 0, got $rc: $out"
  [ "$(printf '%s' "$out" | jq -r '.decision')" = "allow" ] || fail "Stop command must emit allow, got: $out"

  # PreToolUse with non-delegation tool should allow and exit 0
  rc=0
  out=$(printf '{"toolCall":{"name":"run_command"}}' | (cd "$ROOT" && eval "$pretool_cmd")) || rc=$?
  [ "$rc" -eq 0 ] || fail "PreToolUse command on non-delegation tool must exit 0, got $rc: $out"

  pass "hooks.json: Stop and PreToolUse commands execute cleanly with valid decisions"
}

test_turnend_guard_supports_agy_flag
test_park_inert_when_not_primary
test_park_inert_on_foreign_host
test_park_inert_on_non_model_stop
test_park_inert_in_away_mode
test_park_inert_when_supervision_not_needed
test_park_delivers_actionable_wake
test_park_delivers_repair_followup_and_bounds_budget
test_park_enforces_loop_ceiling
test_park_supersession_stands_down
test_hooks_json_commands_execute_cleanly

