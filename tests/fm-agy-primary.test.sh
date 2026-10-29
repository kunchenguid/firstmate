#!/usr/bin/env bash
# Behavior tests for Antigravity CLI (agy) as a firstmate PRIMARY and SECONDMATE
# harness (.agents/hooks.json, bin/fm-sessionstart-agy.sh,
# bin/fm-turnend-guard-agy.sh, bin/fm-turnend-guard.sh --agy,
# PreToolUse --agy seatbelts, session-lock agy ancestry, and supervision model).
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
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

run_under_agy() {
  env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
      -u PI_CODING_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u GROK_AGENT \
      "$@" "$FAKE_AGY" -c "$AGY_CHILD_CMD"
}

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs" "$dir/.agents"
  for f in fm-sessionstart-agy.sh fm-turnend-guard-agy.sh \
           fm-turnend-guard.sh fm-sessionstart-run.sh fm-sessionstart-nudge.sh \
           fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh \
           fm-claude-stop-autoarm.sh fm-hook-host-lib.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh fm-path-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-gemini-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-gate-refuse-lib.sh fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh \
           fm-supervision-engine-lib.sh fm-lease-lib.sh; do
    if [ -f "$ROOT/bin/$f" ]; then
      cp "$ROOT/bin/$f" "$dir/bin/$f"
      chmod +x "$dir/bin/$f"
    fi
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  if [ -f "$ROOT/.agents/hooks.json" ]; then
    cp "$ROOT/.agents/hooks.json" "$dir/.agents/hooks.json"
  fi
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

install_digest_fixture() {
  local dir=$1
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
printf '%s\n' "$*" >> "$FM_HOME/state/digest-args"
"$SCRIPT_DIR/fm-lock.sh" || true
"$SCRIPT_DIR/fm-supervision-instructions.sh"
SH
  chmod +x "$dir/bin/fm-session-start.sh"
}

# An arm fixture standing in for bin/fm-watch-arm.sh, speaking its real output
# contract: a "watcher: ..." status line, then the watcher's reason line on an
# actionable close, or a FAILED line and a nonzero exit.
write_arm_fixture() {  # <dir> <kind>
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: state/task1.status\n'
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
    slow-failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
sleep 1.5
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    attached-close)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 1s)\n' "$$"
exit 0
SH
      ;;
    slow)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
i=0
while [ ! -e "$FM_HOME/state/arm-release" ] && [ "$i" -lt 600 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf 'signal: state/task1.status\n'
exit 0
SH
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A supervision host fixture standing in for bin/fm-supervision-host.sh: it
# records its primary pin and arguments, then closes the way <kind> says.
write_host_fixture() {  # <dir> <kind>
  local dir=$1 kind=$2
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\t%%s\\n" "${FM_SUPERVISION_HOST_PRIMARY:-}" "$*" >> "$FM_HOME/state/host-ran"\n'
    case "$kind" in
      handback)
        printf 'printf "watcher: started pid=%%s (beacon fresh)\\n" "$$"\n'
        printf 'printf "stale: fixture-win needs a look\\n"\n'
        printf 'printf "supervision-host: the away session could not take this wake: fixture; this wake is yours\\n"\n'
        ;;
      stood-down)
        printf 'printf "supervision-host stood down: this session no longer owns supervision\\n"\n'
        ;;
    esac
    printf 'exit 0\n'
  } > "$dir/bin/fm-supervision-host.sh"
  chmod +x "$dir/bin/fm-supervision-host.sh"
}

make_healthy_watcher() {
  local dir=$1 pid=${2:-$$} identity
  mkdir -p "$dir/state/.watch.lock"
  [ -f "$dir/bin/fm-watch.sh" ] || {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/fm-watch.sh"
    chmod +x "$dir/bin/fm-watch.sh"
  }
  identity=$(fm_test_pid_identity "$pid")
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$dir/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  : > "$dir/state/.last-watcher-beat"
}

# --- 1. .agents/hooks.json registration & CWD contract -----------------------

test_agents_hooks_json_registration_and_cwd_contract() {
  local reg dir cmd out status
  reg="$ROOT/.agents/hooks.json"
  [ -f "$reg" ] || fail "firstmate must ship a tracked .agents/hooks.json"
  # agy 1.4.9 reads every top-level key as a named hook spec and silently drops
  # the whole file on any other shape: SessionStart and Stop are flat handler
  # lists, PreToolUse is grouped under matcher/hooks.
  jq -e '
    type == "object" and length > 0
    and all(.[]; type == "object")
    and ([.[] | .SessionStart // empty | .[] | (.command | type) == "string"] | length > 0 and all)
    and ([.[] | .Stop // empty | .[] | (.command | type) == "string"] | length > 0 and all)
    and ([.[] | .PreToolUse // empty | .[] | (.matcher | type) == "string" and ([.hooks[].command | type == "string"] | length > 0 and all)] | length > 0 and all)
  ' "$reg" >/dev/null 2>&1 \
    || fail ".agents/hooks.json must be agy named hook specs with flat SessionStart/Stop and grouped PreToolUse handlers"
  jq -e '[.[] | .Stop // empty | .[].timeout] | length > 0 and all(. == 28800)' "$reg" >/dev/null 2>&1 \
    || fail ".agents/hooks.json Stop must allow the park the 28800s hook budget Cursor and Claude use"

  dir=$(make_primary_dir "$TMP_ROOT/hooks-cwd")
  install_digest_fixture "$dir"

  cmd=$(jq -r '[.[] | .SessionStart // empty | .[].command][0] // empty' "$reg")
  [ -n "$cmd" ] || fail "SessionStart hook command missing from .agents/hooks.json"

  AGY_CHILD_CMD='cd "$FM_HOME/.agents" && eval "$HOOK_CMD"'
  out=$(printf '{"sessionId":"s-1","conversationId":"c-1","workspacePaths":["%s"],"source":"new"}' "$dir" \
    | run_under_agy FM_HOME="$dir" HOOK_CMD="$cmd" 2>/dev/null)
  status=$?
  expect_code 0 "$status" "SessionStart hook command must succeed from .agents/ CWD"
  printf '%s' "$out" | jq -e '.injectSteps[0].systemMessage.systemMessage | length > 0' >/dev/null 2>&1 \
    || fail "SessionStart hook command from .agents/ CWD did not emit injectSteps JSON: $out"

  rm -f "$dir/state/.lock"
  AGY_CHILD_CMD='cd "$FM_HOME" && eval "$HOOK_CMD"'
  out=$(printf '{"sessionId":"s-1","conversationId":"c-1","workspacePaths":["%s"],"source":"new"}' "$dir" \
    | run_under_agy FM_HOME="$dir" HOOK_CMD="$cmd" 2>/dev/null)
  status=$?
  expect_code 0 "$status" "SessionStart hook command must succeed from repo root CWD"
  printf '%s' "$out" | jq -e '.injectSteps[0].systemMessage.systemMessage | length > 0' >/dev/null 2>&1 \
    || fail "SessionStart hook command from repo root CWD did not emit injectSteps JSON: $out"

  pass ".agents/hooks.json: valid JSON and hook commands resolve from both .agents/ and repo root"
}

# --- 2. bin/fm-sessionstart-agy.sh -------------------------------------------

test_sessionstart_agy_primary_secondmate_and_worktree_scope() {
  local dir out msg base sm wt
  dir=$(make_primary_dir "$TMP_ROOT/session-primary")
  install_digest_fixture "$dir"
  [ -x "$dir/bin/fm-sessionstart-agy.sh" ] || fail "bin/fm-sessionstart-agy.sh is missing or not executable"

  AGY_CHILD_CMD='"$FM_HOME/bin/fm-sessionstart-agy.sh"'
  out=$(printf '{"sessionId":"s-1","conversationId":"c-1","workspacePaths":["%s"],"source":"new"}' "$dir" \
    | run_under_agy FM_HOME="$dir" 2>/dev/null)
  [ -f "$dir/state/.lock" ] || fail "fm-sessionstart-agy.sh must acquire state/.lock in primary checkout"
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty' 2>/dev/null)
  assert_contains "$msg" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy" \
    "primary SessionStart must inject agy supervision instructions"

  base=$(make_primary_dir "$TMP_ROOT/session-base")
  sm="$TMP_ROOT/session-sm"
  fm_git_worktree "$base" "$sm" fm/agy-sm-home
  mkdir -p "$sm/state" "$sm/data" "$sm/config"
  : > "$sm/AGENTS.md"
  printf 'sm-agy\n' > "$sm/.fm-secondmate-home"
  install_scripts "$sm"
  install_digest_fixture "$sm"

  AGY_CHILD_CMD='"$FM_HOME/bin/fm-sessionstart-agy.sh"'
  out=$(printf '{"sessionId":"s-2","conversationId":"c-2","workspacePaths":["%s"],"source":"new"}' "$sm" \
    | run_under_agy FM_HOME="$sm" FM_ROOT_OVERRIDE="$sm" 2>/dev/null)
  [ -f "$sm/state/.lock" ] || fail "fm-sessionstart-agy.sh must acquire state/.lock in seeded secondmate worktree"
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty' 2>/dev/null)
  assert_contains "$msg" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy" \
    "secondmate SessionStart must inject agy supervision instructions"

  wt="$TMP_ROOT/session-crew-wt"
  git -C "$base" worktree add --quiet -b fm/agy-crew-wt "$wt"
  mkdir -p "$wt/state"
  : > "$wt/AGENTS.md"
  install_scripts "$wt"
  install_digest_fixture "$wt"

  AGY_CHILD_CMD='"$FM_HOME/bin/fm-sessionstart-agy.sh"'
  out=$(printf '{"sessionId":"s-3","conversationId":"c-3","workspacePaths":["%s"],"source":"new"}' "$wt" \
    | run_under_agy FM_HOME="$wt" FM_ROOT_OVERRIDE="$wt" 2>/dev/null)
  assert_equals "{}" "$out" "crewmate worktree without .fm-secondmate-home must emit {}"
  [ ! -e "$wt/state/.lock" ] || fail "crewmate worktree must not create state/.lock"

  pass "fm-sessionstart-agy: runs in primary and seeded secondmate homes, stands down with {} in crewmate worktree"
}

# --- 3. bin/fm-turnend-guard-agy.sh & bin/fm-turnend-guard.sh --agy ----------

run_agy_stop() {
  local dir=$1 payload=$2
  AGY_CHILD_CMD='
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-turnend-guard-agy.sh"
  '
  printf '%s' "$payload" | run_under_agy FM_HOME="$dir" FM_AGY_PARK_POLL=1 2>/dev/null
}

test_turnend_guard_agy_actionable_wake_followup() {
  local dir payload out decision reason
  dir=$(make_primary_dir "$TMP_ROOT/stop-wake")
  [ -x "$dir/bin/fm-turnend-guard-agy.sh" ] || fail "bin/fm-turnend-guard-agy.sh is missing or not executable"
  : > "$dir/state/task1.meta"
  printf '2\n' > "$dir/state/.turnend-blocks"
  write_arm_fixture "$dir" actionable
  write_host_fixture "$dir" handback
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  out=$(run_agy_stop "$dir" "$payload")
  decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_equals "continue" "$decision" "actionable wake must return decision=continue"
  assert_contains "$reason" "signal: state/task1.status" "reason must include the wake line"
  assert_contains "$reason" "bin/fm-wake-drain.sh" "reason must carry the drain instruction"
  [ -e "$dir/state/arm-ran" ] || fail "a home without config/supervision-host must park on bin/fm-watch-arm.sh"
  [ ! -e "$dir/state/host-ran" ] || fail "a home without config/supervision-host ran the supervision host"
  [ ! -e "$dir/state/.turnend-blocks" ] || fail "actionable wake must reset state/.turnend-blocks"
  pass "fm-turnend-guard-agy: actionable arm close returns continue decision and resets turnend-blocks"
}

test_turnend_guard_agy_supervision_host_park() {
  local dir payload out reason
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  dir=$(make_primary_dir "$TMP_ROOT/stop-host")
  : > "$dir/state/task1.meta"
  : > "$dir/config/supervision-host"
  write_arm_fixture "$dir" actionable
  write_host_fixture "$dir" handback
  out=$(run_agy_stop "$dir" "$payload")
  [ ! -e "$dir/state/arm-ran" ] || fail "an opted-in home ran the plain arm"
  [ "$(cat "$dir/state/host-ran")" = "$(printf 'agy\tpark')" ] \
    || fail "the park must run the host as 'park' with the agy primary pin: $(cat "$dir/state/host-ran")"
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_contains "$reason" "supervision-host: the away session could not take this wake" \
    "a handed-back wake must carry the supervision-host line"
  assert_contains "$reason" "stale: fixture-win needs a look" "a handed-back wake must carry the wake line"

  dir=$(make_primary_dir "$TMP_ROOT/stop-host-down")
  : > "$dir/state/task1.meta"
  : > "$dir/config/supervision-host"
  write_host_fixture "$dir" stood-down
  out=$(run_agy_stop "$dir" "$payload")
  assert_equals "{}" "$out" "a host that stood down must end the park with {}"
  pass "fm-turnend-guard-agy: an opted-in home parks on the supervision host with the agy pin"
}

test_turnend_guard_agy_park_timeout_rearms() {
  local dir payload out decision reason
  dir=$(make_primary_dir "$TMP_ROOT/stop-timeout")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" slow
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  out=$(FM_AGY_PARK_TIMEOUT=1 run_agy_stop "$dir" "$payload")
  decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_equals "continue" "$decision" "park timeout must return decision=continue"
  assert_contains "$reason" "[supervision-park]" "park timeout reason must include [supervision-park]"
  ! kill -0 "$(cat "$dir/state/arm-ran")" 2>/dev/null || fail "park timeout must stop the arm child"

  dir=$(make_primary_dir "$TMP_ROOT/stop-timeout-total")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" slow-failed
  out=$(FM_AGY_PARK_TIMEOUT=2 run_agy_stop "$dir" "$payload")
  [ "$(wc -l < "$dir/state/arm-ran")" -eq 1 ] \
    || fail "FM_AGY_PARK_TIMEOUT must bound the total park, not grant each arm attempt a fresh budget"
  pass "fm-turnend-guard-agy: park timeout stops the arm and returns continue with [supervision-park]"
}

test_turnend_guard_agy_fleet_empty_and_healthy_close() {
  local dir payload out status
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  dir=$(make_primary_dir "$TMP_ROOT/stop-empty")
  write_arm_fixture "$dir" actionable
  out=$(run_agy_stop "$dir" "$payload")
  status=$?
  expect_code 0 "$status" "empty fleet must exit 0"
  assert_equals "{}" "$out" "empty fleet must return {}"
  [ ! -e "$dir/state/arm-ran" ] || fail "empty fleet must not park"

  dir=$(make_primary_dir "$TMP_ROOT/stop-healthy")
  : > "$dir/state/task1.meta"
  printf '2\n' > "$dir/state/.turnend-blocks"
  write_arm_fixture "$dir" attached-close
  make_healthy_watcher "$dir" "$$"
  out=$(run_agy_stop "$dir" "$payload")
  assert_equals "{}" "$out" "a non-actionable close beside a healthy watcher must return {}"
  [ ! -e "$dir/state/.turnend-blocks" ] || fail "a healthy close must reset state/.turnend-blocks"
  pass "fm-turnend-guard-agy: returns {} when the fleet is empty or a healthy watcher owns the home"
}

test_turnend_guard_agy_non_normal_termination_reasons() {
  local dir reason_code payload out status
  dir=$(make_primary_dir "$TMP_ROOT/stop-reasons")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  for reason_code in USER_CANCELED ERROR MAX_INVOCATIONS MAX_FORCED_INVOCATIONS MAX_TOKEN_BUDGET_EXCEEDED; do
    payload=$(printf '{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"%s"}' "$reason_code")
    out=$(run_agy_stop "$dir" "$payload")
    status=$?
    expect_code 0 "$status" "terminationReason=$reason_code must exit 0"
    assert_equals "{}" "$out" "terminationReason=$reason_code must return {}"
    [ ! -e "$dir/state/arm-ran" ] || fail "terminationReason=$reason_code must not park"
  done
  pass "fm-turnend-guard-agy: non-normal terminationReason values pass through with {}"
}

test_turnend_guard_agy_loop_ceiling() {
  local dir payload out decision reason
  dir=$(make_primary_dir "$TMP_ROOT/stop-ceiling")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":4,"terminationReason":"NO_TOOL_CALL"}'
  out=$(FM_AGY_TURNEND_LOOP_CEILING=4 run_agy_stop "$dir" "$payload")
  decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_equals "continue" "$decision" "reaching the ceiling with work in flight must notify once"
  assert_contains "$reason" "CEILING REACHED" "the ceiling notice must name the ceiling"
  [ ! -e "$dir/state/arm-ran" ] || fail "the ceiling must not park"

  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":5,"terminationReason":"NO_TOOL_CALL"}'
  out=$(FM_AGY_TURNEND_LOOP_CEILING=4 run_agy_stop "$dir" "$payload")
  assert_equals "{}" "$out" "past the ceiling must return {}"
  [ ! -e "$dir/state/arm-ran" ] || fail "past the ceiling must not park"

  rm -f "$dir/state/task1.meta"
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":4,"terminationReason":"NO_TOOL_CALL"}'
  out=$(FM_AGY_TURNEND_LOOP_CEILING=4 run_agy_stop "$dir" "$payload")
  assert_equals "{}" "$out" "reaching the ceiling with nothing to supervise must return {}"
  pass "fm-turnend-guard-agy: the loop ceiling notifies once while supervision is needed, then passes through"
}

test_turnend_guard_agy_supersession() {
  local dir payload first_pid waited first_out
  dir=$(make_primary_dir "$TMP_ROOT/stop-supersede")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" slow
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  ( run_agy_stop "$dir" "$payload" > "$dir/state/first-out" ) &
  first_pid=$!
  waited=0
  while [ ! -s "$dir/state/.agy-park-owner" ] || [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "first park never wrote state/.agy-park-owner"
  done
  printf 'superseded-owner\n' > "$dir/state/.agy-park-owner"
  wait "$first_pid" 2>/dev/null || true
  first_out=$(cat "$dir/state/first-out" 2>/dev/null || true)
  assert_equals "{}" "$first_out" "superseded park must return {}"
  ! kill -0 "$(cat "$dir/state/arm-ran")" 2>/dev/null || fail "a superseded park must stop its arm child"
  pass "fm-turnend-guard-agy: superseded park owner returns {}"
}

test_turnend_guard_agy_bounded_repair_nag() {
  local dir payload out decision i
  dir=$(make_primary_dir "$TMP_ROOT/stop-nag")
  : > "$dir/state/task1.meta"
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL"}'
  for i in 1 2 3; do
    out=$(printf '%s' "$payload" | FM_HOME="$dir" FM_TURNEND_MAX_BLOCKS=3 bash "$dir/bin/fm-turnend-guard.sh" --agy 2>/dev/null)
    decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
    assert_equals "continue" "$decision" "repair nag $i from fm-turnend-guard.sh --agy must return decision=continue"
  done
  out=$(printf '%s' "$payload" | FM_HOME="$dir" FM_TURNEND_MAX_BLOCKS=3 bash "$dir/bin/fm-turnend-guard.sh" --agy 2>/dev/null)
  assert_equals "{}" "$out" "4th block from fm-turnend-guard.sh --agy must fail open with {}"

  dir=$(make_primary_dir "$TMP_ROOT/stop-park-nag")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  for i in 1 2 3; do
    out=$(run_agy_stop "$dir" "$payload")
    decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
    assert_equals "continue" "$decision" "repair nag $i from fm-turnend-guard-agy.sh must return decision=continue"
  done
  [ "$(wc -l < "$dir/state/arm-ran")" -eq 6 ] || fail "each failed park must make two bounded arm attempts"
  out=$(run_agy_stop "$dir" "$payload")
  assert_equals "{}" "$out" "4th block from fm-turnend-guard-agy.sh must fail open with {}"
  pass "fm-turnend-guard --agy & fm-turnend-guard-agy: bounded repair nag blocks 3 times then fails open with {}"
}

# --- 4. PreToolUse seatbelts (--agy mode) ------------------------------------

test_arm_pretool_check_agy() {
  local dir payload out status decision reason cmd
  dir=$(make_primary_dir "$TMP_ROOT/pretool-arm")

  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch.sh"}}}'
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-arm-pretool-check.sh" --agy 2>/dev/null)
  status=$?
  expect_code 0 "$status" "fm-arm-pretool-check.sh --agy deny must exit 0"
  decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_equals "deny" "$decision" "fm-arm-pretool-check.sh --agy must deny a direct foreground watcher"
  assert_contains "$reason" "[watcher-direct]" "direct watcher deny must carry the shared policy code"

  make_healthy_watcher "$dir" "$$"
  for cmd in "git status" "bin/fm-watch-arm.sh --stop" "cat bin/fm-watch-arm.sh"; do
    payload=$(jq -cn --arg c "$cmd" '{toolCall:{name:"run_command",args:{CommandLine:$c}}}')
    out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-arm-pretool-check.sh" --agy 2>/dev/null)
    status=$?
    expect_code 0 "$status" "fm-arm-pretool-check.sh --agy allow must exit 0 for: $cmd"
    [ -z "$out" ] || fail "fm-arm-pretool-check.sh --agy must allow '$cmd', got: $out"
  done
  pass "fm-arm-pretool-check --agy: denies through the shared policy and allows ordinary commands"
}

test_cd_pretool_check_agy() {
  local dir wt payload out status decision reason
  dir=$(make_primary_dir "$TMP_ROOT/pretool-cd")

  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/demo"}}}'
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" --agy 2>/dev/null)
  status=$?
  expect_code 0 "$status" "fm-cd-pretool-check.sh --agy deny must exit 0"
  decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_equals "deny" "$decision" "fm-cd-pretool-check.sh --agy must deny bare cd in primary checkout"
  assert_contains "$reason" "[persistent-cd]" "cd deny reason must contain [persistent-cd]"

  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"(cd projects/demo && pwd)"}}}'
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" --agy 2>/dev/null)
  status=$?
  expect_code 0 "$status" "subshell cd must exit 0"
  [ -z "$out" ] || fail "subshell cd must produce empty stdout, got: $out"

  wt="$TMP_ROOT/pretool-cd-wt"
  fm_git_worktree "$dir" "$wt" fm/agy-cd-wt
  mkdir -p "$wt/state"
  : > "$wt/AGENTS.md"
  install_scripts "$wt"
  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/demo"}}}'
  out=$(printf '%s' "$payload" | FM_HOME="$wt" FM_ROOT_OVERRIDE="$wt" bash "$wt/bin/fm-cd-pretool-check.sh" --agy 2>/dev/null)
  status=$?
  expect_code 0 "$status" "linked crewmate worktree cd check must exit 0"
  [ -z "$out" ] || fail "linked crewmate worktree cd check must be inert, got: $out"
  pass "fm-cd-pretool-check --agy: denies persistent cd in primary, allows subshell cd, inert in worktree"
}

test_subagent_pretool_check_agy() {
  local dir wt payload out status decision reason tool_name
  dir=$(make_primary_dir "$TMP_ROOT/pretool-subagent")

  payload='{"toolCall":{"name":"invoke_subagent","args":{"TypeName":"research"}}}'
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-subagent-pretool-check.sh" --agy 2>/dev/null)
  status=$?
  expect_code 0 "$status" "fm-subagent-pretool-check.sh --agy deny must exit 0"
  decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
  assert_equals "deny" "$decision" "fm-subagent-pretool-check.sh --agy must deny invoke_subagent in primary checkout"
  assert_contains "$reason" "[subagent-dispatch]" "subagent deny reason must contain [subagent-dispatch]"

  for tool_name in manage_subagents manage_task; do
    payload=$(printf '{"toolCall":{"name":"%s","args":{"Action":"list"}}}' "$tool_name")
    out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-subagent-pretool-check.sh" --agy 2>/dev/null)
    status=$?
    expect_code 0 "$status" "$tool_name must exit 0"
    [ -z "$out" ] || fail "$tool_name must be allowed as observe-only, got: $out"
  done

  wt="$TMP_ROOT/pretool-subagent-wt"
  fm_git_worktree "$dir" "$wt" fm/agy-subagent-wt
  mkdir -p "$wt/state"
  : > "$wt/AGENTS.md"
  install_scripts "$wt"
  payload='{"toolCall":{"name":"invoke_subagent","args":{"TypeName":"research"}}}'
  out=$(printf '%s' "$payload" | FM_HOME="$wt" FM_ROOT_OVERRIDE="$wt" bash "$wt/bin/fm-subagent-pretool-check.sh" --agy 2>/dev/null)
  status=$?
  expect_code 0 "$status" "linked crewmate worktree subagent check must exit 0"
  [ -z "$out" ] || fail "linked crewmate worktree subagent check must be inert, got: $out"
  pass "fm-subagent-pretool-check --agy: denies invoke_subagent, allows observe-only tools, inert in worktree"
}

# --- 5. Session lock agy ancestry & Supervision model ------------------------

test_session_lock_agy_ancestry_and_supervision_model() {
  local dir out model block repair
  dir=$(make_primary_dir "$TMP_ROOT/lock-ancestry")

  AGY_CHILD_CMD='
    . "$FM_HOME/bin/fm-session-lock-lib.sh"
    anc=$(fm_harness_ancestry_pid) || exit 11
    [ "$anc" = "$PPID" ] || exit 12
    fm_harness_pid_alive "$anc" || exit 13
    printf "%s\n" "$anc" > "$FM_HOME/state/.lock"
    fm_session_lock_owned_by_self "$FM_HOME/state" || exit 14
    printf "owned:%s\n" "$anc"
  '
  out=$(run_under_agy FM_HOME="$dir" 2>/dev/null)
  assert_contains "$out" "owned:" "session-lock-lib must resolve agy ancestry, liveness, and ownership"

  AGY_CHILD_CMD='
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_supervision_model
  '
  model=$(run_under_agy FM_HOME="$dir" 2>/dev/null)
  assert_equals "autoarm" "$model" "fm_supervision_model must return autoarm when fm-harness.sh detects agy"

  block=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy 2>/dev/null || true)
  assert_contains "$block" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy" \
    "fm-supervision-instructions.sh --harness agy must emit the agy header"
  assert_contains "$block" "Mode: Antigravity Stop-hook-owned supervision." \
    "fm-supervision-instructions.sh --harness agy must emit the Antigravity mode line"
  assert_contains "$block" "bin/fm-turnend-guard-agy.sh" \
    "fm-supervision-instructions.sh --harness agy must reference bin/fm-turnend-guard-agy.sh"

  repair=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy --repair-line 2>/dev/null || true)
  assert_contains "$repair" "Stop-hook park" \
    "fm-supervision-instructions.sh --harness agy --repair-line must mention Stop-hook park"

  pass "session-lock & supervision model: agy ancestry, autoarm model, and supervision instructions verified"
}

fm_test_run \
  test_agents_hooks_json_registration_and_cwd_contract \
  test_sessionstart_agy_primary_secondmate_and_worktree_scope \
  test_turnend_guard_agy_actionable_wake_followup \
  test_turnend_guard_agy_supervision_host_park \
  test_turnend_guard_agy_park_timeout_rearms \
  test_turnend_guard_agy_fleet_empty_and_healthy_close \
  test_turnend_guard_agy_non_normal_termination_reasons \
  test_turnend_guard_agy_loop_ceiling \
  test_turnend_guard_agy_supersession \
  test_turnend_guard_agy_bounded_repair_nag \
  test_arm_pretool_check_agy \
  test_cd_pretool_check_agy \
  test_subagent_pretool_check_agy \
  test_session_lock_agy_ancestry_and_supervision_model
