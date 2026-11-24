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
           fm-session-lock-lib.sh fm-omp-process-lib.sh fm-cursor-lib.sh fm-gemini-lib.sh fm-hermes-process-lib.sh fm-operational-input.sh \
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

# An empty helper block is kept free of dead parking fixtures; tests below
# verify non-blocking Stop-hook guard behavior.

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
  jq -e '[.[] | .Stop // empty | .[].timeout] | length > 0 and all(. == 30)' "$reg" >/dev/null 2>&1 \
    || fail ".agents/hooks.json Stop must use a fast non-blocking 30s timeout"

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

  AGY_CHILD_CMD='
    dive() {
      if [ "$1" -le 0 ]; then
        "$FM_HOME/bin/fm-harness.sh"
      else
        bash -c "dive $(( $1 - 1 ))"
      fi
    }
    export -f dive
    dive 10
  '
  out=$(run_under_agy FM_HOME="$dir" 2>/dev/null)
  assert_equals "agy" "$out" "deep 10-hop hook ancestry must still detect agy rather than unknown"

  pass "fm-sessionstart-agy: runs in primary and seeded secondmate homes, stands down in worktree, and detects agy across 10+ hops"
}

# --- 3. bin/fm-turnend-guard-agy.sh & bin/fm-turnend-guard.sh --agy ----------

run_agy_stop() {
  local dir=$1 payload=$2
  AGY_CHILD_CMD='
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-turnend-guard-agy.sh"
  '
  printf '%s' "$payload" | run_under_agy FM_HOME="$dir" 2>/dev/null
}

test_turnend_guard_agy_empty_fleet_and_healthy_watcher() {
  local dir payload out status
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL","continuationActive":false}'
  dir=$(make_primary_dir "$TMP_ROOT/stop-empty")
  out=$(run_agy_stop "$dir" "$payload")
  status=$?
  expect_code 0 "$status" "empty fleet must exit 0"
  assert_equals "{}" "$out" "empty fleet must return {}"

  dir=$(make_primary_dir "$TMP_ROOT/stop-healthy")
  : > "$dir/state/task1.meta"
  printf '2\n' > "$dir/state/.turnend-blocks"
  make_healthy_watcher "$dir" "$$"
  out=$(run_agy_stop "$dir" "$payload")
  status=$?
  expect_code 0 "$status" "healthy watcher must exit 0"
  assert_equals "{}" "$out" "healthy watcher must return {}"
  [ ! -e "$dir/state/.turnend-blocks" ] || fail "healthy watcher must reset state/.turnend-blocks"
  pass "fm-turnend-guard-agy: returns {} immediately when fleet is empty or watcher is healthy"
}

test_turnend_guard_agy_bounded_repair_nag() {
  local dir payload out decision reason i
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL","continuationActive":false}'

  dir=$(make_primary_dir "$TMP_ROOT/stop-nag-direct")
  : > "$dir/state/task1.meta"
  for i in 1 2 3; do
    out=$(printf '%s' "$payload" | FM_HOME="$dir" FM_TURNEND_MAX_BLOCKS=3 bash "$dir/bin/fm-turnend-guard.sh" --agy 2>/dev/null)
    decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
    assert_equals "continue" "$decision" "repair nag $i from fm-turnend-guard.sh --agy must return decision=continue"
  done
  out=$(printf '%s' "$payload" | FM_HOME="$dir" FM_TURNEND_MAX_BLOCKS=3 bash "$dir/bin/fm-turnend-guard.sh" --agy 2>/dev/null)
  assert_equals "{}" "$out" "4th block from fm-turnend-guard.sh --agy must fail open with {}"

  dir=$(make_primary_dir "$TMP_ROOT/stop-nag-wrapper")
  : > "$dir/state/task1.meta"
  for i in 1 2 3; do
    out=$(run_agy_stop "$dir" "$payload")
    decision=$(printf '%s' "$out" | jq -r '.decision // empty' 2>/dev/null)
    reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
    assert_equals "continue" "$decision" "repair nag $i from fm-turnend-guard-agy.sh must return decision=continue"
    assert_contains "$reason" "TURN WOULD END BLIND" "repair nag $i must carry TURN WOULD END BLIND"
    assert_contains "$reason" "bin/fm-watch-arm.sh" "repair nag $i must name bin/fm-watch-arm.sh"
  done
  out=$(run_agy_stop "$dir" "$payload")
  assert_equals "{}" "$out" "4th block from fm-turnend-guard-agy.sh must fail open with {}"
  pass "fm-turnend-guard --agy & fm-turnend-guard-agy: bounded repair nag blocks 3 times then fails open with {}"
}

test_turnend_guard_agy_non_normal_reasons() {
  local dir reason_code payload out status
  dir=$(make_primary_dir "$TMP_ROOT/stop-reasons")
  : > "$dir/state/task1.meta"

  for reason_code in USER_CANCELED ERROR MAX_INVOCATIONS MAX_FORCED_INVOCATIONS MAX_TOKEN_BUDGET_EXCEEDED; do
    payload=$(printf '{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"%s","continuationActive":false}' "$reason_code")
    out=$(run_agy_stop "$dir" "$payload")
    status=$?
    expect_code 0 "$status" "terminationReason=$reason_code must exit 0"
    assert_equals "{}" "$out" "terminationReason=$reason_code must return {}"
  done
  pass "fm-turnend-guard-agy: non-normal terminationReason values pass through with {}"
}

test_turnend_guard_agy_foreign_lock_and_worktree_scope() {
  local dir wt foreign_pid payload out status
  payload='{"sessionId":"s-1","conversationId":"c-1","executionNum":1,"terminationReason":"NO_TOOL_CALL","continuationActive":false}'

  dir=$(make_primary_dir "$TMP_ROOT/stop-foreign-lock")
  : > "$dir/state/task1.meta"
  env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
      -u PI_CODING_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u GROK_AGENT \
      "$FAKE_AGY" -c 'sleep 10' >/dev/null 2>&1 &
  foreign_pid=$!
  sleep 0.2
  printf '%s\n' "$foreign_pid" > "$dir/state/.lock"
  AGY_CHILD_CMD='"$FM_HOME/bin/fm-turnend-guard-agy.sh"'
  out=$(printf '%s' "$payload" | run_under_agy FM_HOME="$dir" 2>/dev/null)
  status=$?
  kill "$foreign_pid" 2>/dev/null || true
  wait "$foreign_pid" 2>/dev/null || true
  expect_code 0 "$status" "foreign live lock owner must exit 0"
  assert_equals "{}" "$out" "foreign live lock owner must return {}"

  wt="$TMP_ROOT/stop-crew-wt"
  fm_git_worktree "$dir" "$wt" fm/agy-stop-wt
  mkdir -p "$wt/state"
  : > "$wt/AGENTS.md"
  : > "$wt/state/task1.meta"
  install_scripts "$wt"
  AGY_CHILD_CMD='"$FM_HOME/bin/fm-turnend-guard-agy.sh"'
  out=$(printf '%s' "$payload" | run_under_agy FM_HOME="$wt" FM_ROOT_OVERRIDE="$wt" 2>/dev/null)
  status=$?
  expect_code 0 "$status" "linked crewmate worktree must exit 0"
  assert_equals "{}" "$out" "linked crewmate worktree must return {}"
  pass "fm-turnend-guard-agy: stands down for foreign lock owner and linked crewmate worktree"
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
  assert_equals "persistent" "$model" "fm_supervision_model must return persistent when fm-harness.sh detects agy"

  block=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy 2>/dev/null || true)
  assert_contains "$block" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy" \
    "fm-supervision-instructions.sh --harness agy must emit the agy header"
  assert_contains "$block" "Mode: Antigravity background-notify supervision." \
    "fm-supervision-instructions.sh --harness agy must emit the Antigravity mode line"
  assert_contains "$block" "bin/fm-watch-arm.sh" \
    "fm-supervision-instructions.sh --harness agy must reference bin/fm-watch-arm.sh"

  repair=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy --repair-line 2>/dev/null || true)
  assert_contains "$repair" "Antigravity tracked background run_command" \
    "fm-supervision-instructions.sh --harness agy --repair-line must mention Antigravity tracked background run_command"

  pass "session-lock & supervision model: agy ancestry, persistent model, and supervision instructions verified"
}

fm_test_run \
  test_agents_hooks_json_registration_and_cwd_contract \
  test_sessionstart_agy_primary_secondmate_and_worktree_scope \
  test_turnend_guard_agy_empty_fleet_and_healthy_watcher \
  test_turnend_guard_agy_bounded_repair_nag \
  test_turnend_guard_agy_non_normal_reasons \
  test_turnend_guard_agy_foreign_lock_and_worktree_scope \
  test_arm_pretool_check_agy \
  test_cd_pretool_check_agy \
  test_subagent_pretool_check_agy \
  test_session_lock_agy_ancestry_and_supervision_model
