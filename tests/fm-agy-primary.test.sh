#!/usr/bin/env bash
# Behavior tests for Antigravity CLI (agy) as a firstmate PRIMARY
# (docs/turnend-guard.md, docs/supervision-protocols/agy.md, docs/verification/agy.md).
#
# Hermetic tests over temp directories with real processes and no external
# network or model calls, so CI enforces them everywhere:
#   SESSION LOCK - bin/fm-session-lock-lib.sh recognizes agy in process ancestry.
#   SESSIONSTART - bin/fm-sessionstart-agy.sh formats digest into ephemeralMessage injection.
#   PRETOOLUSE   - bin/fm-pretool-check-agy.sh denies delegation, backgrounding, and cd.
#   STOP / GUARD - bin/fm-turnend-guard-agy.sh checks watcher health and bounds loops.
#   HOOKS CONFIG - .agents/hooks.json structure and configuration validity.
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

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard-agy.sh fm-turnend-guard.sh fm-sessionstart-agy.sh \
           fm-sessionstart-run.sh fm-sessionstart-nudge.sh fm-pretool-check-agy.sh \
           fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh \
           fm-hook-host-lib.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
           fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-gemini-lib.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-gate-refuse-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir"/bin/*.sh
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

make_worktree_dir() {
  local primary=$1 wt=$2
  mkdir -p "$(dirname "$wt")"
  git -C "$primary" worktree add -q -b "branch-$(basename "$wt")" "$wt"
  mkdir -p "$wt/state"
  install_scripts "$wt"
  printf '%s\n' "$wt"
}

test_agents_hooks_json_structure() {
  local hooks_file="$ROOT/.agents/hooks.json"
  [ -f "$hooks_file" ] || fail ".agents/hooks.json must exist"
  command -v jq >/dev/null 2>&1 || fail "test requires jq"

  jq -e '.["firstmate-agy"].SessionStart' "$hooks_file" >/dev/null 2>&1 \
    || fail ".agents/hooks.json must define SessionStart"
  jq -e '.["firstmate-agy"].PreToolUse' "$hooks_file" >/dev/null 2>&1 \
    || fail ".agents/hooks.json must define PreToolUse"
  jq -e '.["firstmate-agy"].Stop' "$hooks_file" >/dev/null 2>&1 \
    || fail ".agents/hooks.json must define Stop"

  local pretool_matcher
  pretool_matcher=$(jq -r '.["firstmate-agy"].PreToolUse[0].matcher' "$hooks_file")
  [ "$pretool_matcher" = "*" ] || fail "PreToolUse matcher must be *, got '$pretool_matcher'"

  local start_cmd pretool_cmd stop_cmd
  start_cmd=$(jq -r '.["firstmate-agy"].SessionStart[0].command' "$hooks_file")
  pretool_cmd=$(jq -r '.["firstmate-agy"].PreToolUse[0].hooks[0].command' "$hooks_file")
  stop_cmd=$(jq -r '.["firstmate-agy"].Stop[0].command' "$hooks_file")

  assert_contains "$start_cmd" "fm-sessionstart-agy.sh" "SessionStart must invoke fm-sessionstart-agy.sh"
  assert_contains "$pretool_cmd" "fm-pretool-check-agy.sh" "PreToolUse must invoke fm-pretool-check-agy.sh"
  assert_contains "$stop_cmd" "fm-turnend-guard-agy.sh" "Stop must invoke fm-turnend-guard-agy.sh"

  pass ".agents/hooks.json: defines SessionStart, PreToolUse wildcard, and Stop"
}

test_supervision_instructions_for_agy() {
  local out repair
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy" \
    "supervision instructions did not announce agy primary"
  assert_contains "$out" "Mode: AGY foreground checkpoint." \
    "supervision instructions did not include AGY protocol"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" \
    "supervision instructions did not mention foreground checkpoint"

  repair=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy --repair-line)
  assert_contains "$repair" "repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh" \
    "agy repair line was not the foreground checkpoint line"

  pass "fm-supervision-instructions.sh: renders AGY supervision protocol and checkpoint repair line"
}

test_session_lock_ownership_with_agy() {
  local home="$TMP_ROOT/lock-home"
  make_primary_dir "$home" >/dev/null

  # Run inside fake agy process
  "$FAKE_AGY" -c "
    set -u
    # shellcheck source=bin/fm-session-lock-lib.sh
    . '$home/bin/fm-session-lock-lib.sh'
    pids=\$(fm_harness_ancestry_pids)
    [ -n \"\$pids\" ] || exit 1
    # First pid is the fake agy process
    agy_pid=\$(printf '%s\n' \"\$pids\" | head -1)
    printf '%s\n' \"\$agy_pid\" > '$home/state/.lock'
    fm_session_lock_owned_by_self '$home/state' || exit 2
    # Different pid should not be owned
    printf '999999\n' > '$home/state/.lock'
    if fm_session_lock_owned_by_self '$home/state'; then exit 3; fi
    exit 0
  "
  local rc=$?
  expect_code 0 "$rc" "session lock must recognize agy in ancestry as owner"

  pass "fm-session-lock-lib.sh: agy process in ancestry owns session lock"
}

test_sessionstart_agy_adapter() {
  local home="$TMP_ROOT/sessionstart-home"
  local wt="$TMP_ROOT/sessionstart-wt"
  make_primary_dir "$home" >/dev/null
  make_worktree_dir "$home" "$wt" >/dev/null

  # 1. In linked worktree: stands down with empty output
  local out_wt
  out_wt=$(cd "$wt" && FM_ROOT_OVERRIDE="$wt" FM_STATE_OVERRIDE="$wt/state" \
    "$home/bin/fm-sessionstart-agy.sh" --source startup 2>&1)
  [ -z "$out_wt" ] || fail "sessionstart adapter must be silent in linked worktree, got '$out_wt'"

  # 2. In primary home with a simulated digest: formats JSON with ephemeralMessage
  local fake_digest="DIGEST_TEST_LINE_1\nDIGEST_TEST_LINE_2"
  cat > "$home/bin/fm-sessionstart-run.sh" <<SH
#!/usr/bin/env bash
printf '$fake_digest\n'
SH
  chmod +x "$home/bin/fm-sessionstart-run.sh"

  local out_primary
  out_primary=$(cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-sessionstart-agy.sh" --source startup 2>&1)
  assert_contains "$out_primary" '"injectSteps"' "sessionstart output must contain injectSteps"
  assert_contains "$out_primary" '"ephemeralMessage"' "sessionstart output must contain ephemeralMessage"
  assert_contains "$out_primary" "DIGEST_TEST_LINE_1" "sessionstart output must carry digest text"

  # Validate JSON output
  printf '%s\n' "$out_primary" | jq -e '.injectSteps[0].ephemeralMessage' >/dev/null 2>&1 \
    || fail "sessionstart output was not valid AGY injectSteps JSON"

  pass "fm-sessionstart-agy.sh: stands down in worktree and formats injectSteps JSON in primary"
}

test_pretool_check_agy_adapter() {
  local home="$TMP_ROOT/pretool-home"
  local wt="$TMP_ROOT/pretool-wt"
  make_primary_dir "$home" >/dev/null
  make_worktree_dir "$home" "$wt" >/dev/null

  local subagent_payload='{"toolCall":{"name":"invoke_subagent","args":{"Prompt":"do work"}}}'
  local arm_payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch-arm.sh &"}}}'
  local cd_payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/foo"}}}'
  local safe_payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"git status"}}}'

  # 1. In linked worktree: allows all tool calls
  local out_wt
  out_wt=$(printf '%s\n' "$subagent_payload" | (cd "$wt" && FM_ROOT_OVERRIDE="$wt" FM_STATE_OVERRIDE="$wt/state" \
    "$home/bin/fm-pretool-check-agy.sh"))
  [ "$out_wt" = '{"decision": "allow"}' ] || fail "pretool adapter must allow in task worktree, got '$out_wt'"

  # 2. In primary home:
  # 2a. Subagent delegation denial
  local out_sub
  out_sub=$(printf '%s\n' "$subagent_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-pretool-check-agy.sh"))
  assert_contains "$out_sub" '"decision": "deny"' "subagent delegation was not denied"
  assert_contains "$out_sub" 'delegation' "denial reason did not explain delegation"

  # 2b. Backgrounded watcher arm denial
  local out_arm
  out_arm=$(printf '%s\n' "$arm_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-pretool-check-agy.sh"))
  assert_contains "$out_arm" '"decision": "deny"' "backgrounded watcher arm was not denied"

  # 2c. Persistent cd denial
  local out_cd
  out_cd=$(printf '%s\n' "$cd_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-pretool-check-agy.sh"))
  assert_contains "$out_cd" '"decision": "deny"' "persistent cd was not denied"

  # 2d. Safe command allowed
  local out_safe
  out_safe=$(printf '%s\n' "$safe_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-pretool-check-agy.sh"))
  [ "$out_safe" = '{"decision": "allow"}' ] || fail "safe command must be allowed, got '$out_safe'"

  pass "fm-pretool-check-agy.sh: denies delegation, watcher backgrounding, cd; allows safe tools"
}

test_turnend_guard_agy_adapter() {
  local home="$TMP_ROOT/guard-home"
  local wt="$TMP_ROOT/guard-wt"
  make_primary_dir "$home" >/dev/null
  make_worktree_dir "$home" "$wt" >/dev/null

  local stop_payload='{"executionNum":0,"terminationReason":"NO_TOOL_CALL"}'
  local continue_payload='{"executionNum":1,"terminationReason":"NO_TOOL_CALL"}'

  # 1. In linked worktree: allows stop
  local out_wt
  out_wt=$(printf '%s\n' "$stop_payload" | (cd "$wt" && FM_ROOT_OVERRIDE="$wt" FM_STATE_OVERRIDE="$wt/state" \
    "$home/bin/fm-turnend-guard-agy.sh"))
  [ "$out_wt" = '{"decision": "allow"}' ] || fail "turnend guard must allow in worktree, got '$out_wt'"

  # 2. In primary home with no tasks: allows stop
  local out_notasks
  out_notasks=$(printf '%s\n' "$stop_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-turnend-guard-agy.sh"))
  [ "$out_notasks" = '{"decision": "allow"}' ] || fail "turnend guard must allow when no tasks in flight, got '$out_notasks'"

  # 3. In primary home with a task in flight and NO watcher: must continue
  printf 'harness=agy\nwindow=default:1\n' > "$home/state/task-1.meta"
  local out_nowatch
  out_nowatch=$(printf '%s\n' "$stop_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-turnend-guard-agy.sh"))
  assert_contains "$out_nowatch" '"decision": "continue"' "turnend guard must continue when watcher is down"
  assert_contains "$out_nowatch" "TURN WOULD END BLIND" "continue reason must contain repair banner"

  # 4. Bounded loop guard: executionNum >= 1 must allow stop even if watcher is down
  local out_loop
  out_loop=$(printf '%s\n' "$continue_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-turnend-guard-agy.sh"))
  [ "$out_loop" = '{"decision": "allow"}' ] || fail "turnend guard must allow on continuation turn, got '$out_loop'"

  # 5. Read-only session: session lock held by another live verified harness process allows stop
  # Start a foreign agy harness process as the lock owner
  "$FAKE_AGY" -c "exec sleep 5" &
  local foreign_pid=$!
  printf '%s\n' "$foreign_pid" > "$home/state/.lock"
  local out_readonly
  out_readonly=$(printf '%s\n' "$stop_payload" | (cd "$home" && FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-turnend-guard-agy.sh"))
  kill -9 "$foreign_pid" 2>/dev/null || true
  wait "$foreign_pid" 2>/dev/null || true
  [ "$out_readonly" = '{"decision": "allow"}' ] || fail "turnend guard must allow in read-only session, got '$out_readonly'"

  pass "fm-turnend-guard-agy.sh: allows when safe, compels continuation when blind, bounds loop iterations"
}

test_agents_hooks_json_structure
test_supervision_instructions_for_agy
test_session_lock_ownership_with_agy
test_sessionstart_agy_adapter
test_pretool_check_agy_adapter
test_turnend_guard_agy_adapter

echo "# all fm-agy-primary tests passed"
