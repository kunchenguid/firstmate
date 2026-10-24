#!/usr/bin/env bash
# Behavior tests for Antigravity CLI (agy) as a firstmate PRIMARY
# (docs/turnend-guard.md, docs/supervision-protocols/agy.md,
# docs/verification/agy.md).
#
# Hermetic tests over temporary directories with real processes:
#   HOST GUARD  - bin/fm-hook-host-lib.sh, standing down on a foreign-host
#                 payload (such as Cursor).
#   BACKSTOP    - bin/fm-turnend-guard-agy.sh, the non-blocking Stop-hook
#                 backstop for background-notify supervision: immediate allow
#                 when a healthy watcher cycle is running, queued-wake
#                 continuation when state/.wake-queue has unread events,
#                 bounded repair nag when active tasks are in flight with no
#                 healthy watcher, and loop ceiling enforcement.
#   GUARD       - bin/fm-turnend-guard.sh --agy, the shared turn-end guard.
#
# The guard runs as a child of a fake harness executable named agy whose pid
# holds the fixture home's session lock, so the real ancestry path in
# bin/fm-session-lock-lib.sh is exercised rather than stubbed.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-agy-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
export PATH="$FAKEBIN:$PATH"
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
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
  chmod +x "$dir/bin/fm-watch.sh"
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

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

GUARD_CHILD='
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-turnend-guard-agy.sh"
'

run_guard() {  # <dir> [exec_num] [ceiling] [payload_override]
  local dir=$1 exec_num=${2:-1} ceiling=${3:-} payload_override=${4:-} payload
  if [ -n "$payload_override" ]; then
    payload=$payload_override
  else
    payload=$(printf '{"conversationId":"conv-agy-1","executionNum":%s,"terminationReason":"model_stop","fullyIdle":true}' "$exec_num")
  fi
  if [ -n "$ceiling" ]; then
    printf '%s' "$payload" | env FM_HOME="$dir" \
      FM_AGY_TURNEND_LOOP_CEILING="$ceiling" "$FAKE_AGY" -c "$GUARD_CHILD" 2>/dev/null
  else
    printf '%s' "$payload" | env FM_HOME="$dir" \
      "$FAKE_AGY" -c "$GUARD_CHILD" 2>/dev/null
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

test_guard_inert_when_not_primary() {
  local dir child out decision
  dir=$(make_primary_dir "$TMP_ROOT/scope-parent")
  child="$dir/worktrees/task1"
  git -C "$dir" worktree add -q -b task1-branch "$child"
  mkdir -p "$child/state" "$child/bin"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  : > "$child/state/task1.meta"

  out=$(run_guard "$child")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "task worktree must allow stop, got: $out"
  pass "fm-turnend-guard-agy: inert in child task worktrees"
}

test_guard_inert_on_foreign_host() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/host-foreign")
  : > "$dir/state/task1.meta"

  out=$(run_guard "$dir" 1 "" "$CURSOR_PAYLOAD")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "foreign host must allow stop, got: $out"
  pass "fm-turnend-guard-agy: inert on foreign host payload"
}

test_guard_inert_on_non_model_stop() {
  local dir payload out decision
  dir=$(make_primary_dir "$TMP_ROOT/non-model-stop")
  : > "$dir/state/task1.meta"

  payload='{"conversationId":"conv-1","executionNum":1,"terminationReason":"error"}'
  out=$(run_guard "$dir" 1 "" "$payload")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "error termination must allow stop, got: $out"

  payload='{"conversationId":"conv-1","executionNum":1,"terminationReason":"max_steps_exceeded"}'
  out=$(run_guard "$dir" 1 "" "$payload")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "max_steps_exceeded termination must allow stop, got: $out"

  # NO_TOOL_CALL is Antigravity CLI's live enum for text completions and must guard.
  payload='{"conversationId":"conv-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  out=$(run_guard "$dir" 1 "" "$payload")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "NO_TOOL_CALL without healthy watcher must emit continue, got: $out"

  pass "fm-turnend-guard-agy: inert on error/max_steps, active on NO_TOOL_CALL"
}

test_guard_inert_in_away_mode() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/away-mode")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "away mode must allow stop, got: $out"
  pass "fm-turnend-guard-agy: inert in away mode"
}

test_guard_inert_when_supervision_not_needed() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/idle-home")

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "idle home must allow stop, got: $out"
  pass "fm-turnend-guard-agy: inert when no supervision needed"
}

test_guard_inert_when_only_passive_checks_exist() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/passive-checks")
  : > "$dir/state/sample.check.sh"
  chmod +x "$dir/state/sample.check.sh"
  : > "$dir/state/sample.check-trust"
  mkdir -p "$dir/state/procevent"
  : > "$dir/state/procevent/sample.source"

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "home with only passive checks must allow stop, got: $out"
  pass "fm-turnend-guard-agy: inert when only passive checks exist and no work in flight"
}

test_guard_inert_when_inflight_tasks_are_idle() {
  local dir out decision
  dir=$(make_primary_dir "$TMP_ROOT/inflight-idle")
  : > "$dir/state/task1.meta"
  printf 'pr=https://github.com/example/repo/pull/1\n' >> "$dir/state/task1.meta"
  printf 'v1 gen=g1 seq=1 state=idle source=agy-hook event=stop ts=1000\n' > "$dir/state/task1.busy-state"
  printf 'done [at=1000]: pr created\n' > "$dir/state/task1.status"

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "home with only idle PR-registered tasks must allow stop, got: $out"
  pass "fm-turnend-guard-agy: inert when in-flight tasks are idle PR-registered tasks"
}

test_guard_allows_stop_immediately_when_watcher_healthy() {
  local dir wpid ident out decision
  dir=$(make_primary_dir "$TMP_ROOT/healthy-watcher")
  : > "$dir/state/task1.meta"

  # Start a real fm-watch.sh process and record its lock + fresh beacon
  "$dir/bin/fm-watch.sh" >/dev/null 2>&1 &
  wpid=$!
  ident=$(watcher_identity "$dir" "$wpid")
  record_watcher_lock "$dir" "$wpid" "$ident"
  touch "$dir/state/.last-watcher-beat"

  # Seed a non-zero block budget to verify healthy watcher resets it
  printf 'session=conv-agy-1\ncount=2\n' > "$dir/state/.turnend-agy-blocks"

  out=$(run_guard "$dir")
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "healthy background watcher must allow stop immediately, got: $out"
  [ ! -f "$dir/state/.turnend-agy-blocks" ] || fail "healthy watcher must reset block budget"
  pass "fm-turnend-guard-agy: allows stop immediately (<10ms) when background watcher is healthy"
}

test_guard_blocks_when_inflight_task_done_unregistered() {
  local dir out decision reason
  dir=$(make_primary_dir "$TMP_ROOT/inflight-done-unregistered")
  : > "$dir/state/task1.meta"
  printf 'v1 gen=g1 seq=1 state=idle source=agy-hook event=stop ts=1000\n' > "$dir/state/task1.busy-state"
  printf 'done [at=1000]: ready in branch fm/task1\n' > "$dir/state/task1.status"

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "unregistered completed task without watcher must emit continue, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'TURN WOULD END BLIND'*) ;;
    *) fail "expected repair banner in reason, got: $reason" ;;
  esac
  pass "fm-turnend-guard-agy: blocks when completed task awaits landing or PR registration without watcher"
}

test_guard_delivers_queued_wake_even_when_task_worker_idle() {
  local dir out decision reason kind
  dir=$(make_primary_dir "$TMP_ROOT/inflight-wake-idle-worker")
  : > "$dir/state/task1.meta"
  printf 'pr=https://github.com/example/repo/pull/1\n' >> "$dir/state/task1.meta"
  printf 'v1 gen=g1 seq=1 state=idle source=agy-hook event=stop ts=1000\n' > "$dir/state/task1.busy-state"
  printf 'check: pr-poll task1 merged\n' > "$dir/state/.wake-queue"

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "queued wake must deliver continue decision even when tasks are idle, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'check: pr-poll task1 merged'*) ;;
    *) fail "expected queued wake content in reason, got: $reason" ;;
  esac
  case "$reason" in
    *'bin/fm-wake-drain.sh'*) ;;
    *) fail "expected wake drain instruction in reason, got: $reason" ;;
  esac
  kind=$(kind_of_reason "$out")
  [ "$kind" = "watcher" ] || fail "expected operational kind watcher, got: $kind"
  pass "fm-turnend-guard-agy: delivers queued wake immediately even when in-flight tasks are idle"
}

test_guard_delivers_repair_followup_and_bounds_budget() {
  local dir out decision reason i
  dir=$(make_primary_dir "$TMP_ROOT/failed-park")
  : > "$dir/state/task1.meta"

  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "missing watcher must return continue nag 1, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'TURN WOULD END BLIND'*) ;;
    *) fail "expected repair banner in reason, got: $reason" ;;
  esac
  case "$reason" in
    *'WaitMsBeforeAsync: 1000'*) ;;
    *) fail "expected Antigravity tracked background run_command instruction in reason, got: $reason" ;;
  esac

  # Exhaust the BLOCK_BUDGET (3 blocks).
  for i in 2 3; do
    out=$(run_guard "$dir")
    decision=$(decision_of "$out")
    [ "$decision" = "continue" ] || fail "missing watcher must continue through budget ($i), got: $out"
  done

  # 4th attempt must fail open to avoid trapping the user.
  out=$(run_guard "$dir")
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "budget exhaustion must allow stop (fail open), got: $out"
  pass "fm-turnend-guard-agy: repair followup bounds consecutive missing-watcher turns"
}

test_guard_enforces_loop_ceiling() {
  local dir out decision reason
  dir=$(make_primary_dir "$TMP_ROOT/loop-ceiling")
  : > "$dir/state/task1.meta"

  out=$(run_guard "$dir" 180 180)
  decision=$(decision_of "$out")
  [ "$decision" = "continue" ] || fail "loop ceiling hit must return continue, got: $out"
  reason=$(reason_of "$out")
  case "$reason" in
    *'FIRSTMATE SUPERVISION CEILING REACHED'*) ;;
    *) fail "expected ceiling notice in reason, got: $reason" ;;
  esac

  # Beyond ceiling stops emitting continuations.
  out=$(run_guard "$dir" 181 180)
  decision=$(decision_of "$out")
  [ "$decision" = "allow" ] || fail "past ceiling must allow stop, got: $out"
  pass "fm-turnend-guard-agy: enforces loop ceiling"
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

test_supervision_instructions_render_agy_background_protocol() {
  local block repair
  block=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy)
  repair=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy --repair-line)

  case "$block" in
    *'Mode: Antigravity CLI (agy) background-notify supervision.'*) ;;
    *) fail "expected background-notify mode header in agy supervision block, got: $block" ;;
  esac
  case "$block" in
    *'WaitMsBeforeAsync: 1000'*) ;;
    *) fail "expected WaitMsBeforeAsync instruction in agy supervision block, got: $block" ;;
  esac
  case "$repair" in
    *'bin/fm-watch-arm.sh as its own Antigravity tracked background task (run_command with WaitMsBeforeAsync: 1000)'*) ;;
    *) fail "expected background run_command repair instruction, got: $repair" ;;
  esac
  pass "fm-supervision-instructions: renders background-notify protocol and repair line for agy"
}

test_turnend_guard_supports_agy_flag
test_guard_inert_when_not_primary
test_guard_inert_on_foreign_host
test_guard_inert_on_non_model_stop
test_guard_inert_in_away_mode
test_guard_inert_when_supervision_not_needed
test_guard_inert_when_only_passive_checks_exist
test_guard_inert_when_inflight_tasks_are_idle
test_guard_allows_stop_immediately_when_watcher_healthy
test_guard_blocks_when_inflight_task_done_unregistered
test_guard_delivers_queued_wake_even_when_task_worker_idle
test_guard_delivers_repair_followup_and_bounds_budget
test_guard_enforces_loop_ceiling
test_hooks_json_commands_execute_cleanly
test_supervision_instructions_render_agy_background_protocol
