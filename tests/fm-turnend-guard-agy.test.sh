#!/usr/bin/env bash
# Behavior tests for the AGY (Antigravity CLI) primary-harness Phase 1 surface:
#   bin/fm-turnend-guard-agy.sh       AGY Stop-hook turn-end guard
#   bin/fm-hardrule1-pretool-check.sh AGY PreToolUse Hard Rule 1 gate
#   bin/fm-sessionstart-agy-nudge.sh  AGY PreInvocation session-start nudge
# plus the .agents/hooks.json registration they are wired from.
#
# The guard harness payloads match the AGY hooks contract verified from the
# installed Antigravity CLI hooks docs: camelCase stdin JSON, toolCall.name /
# toolCall.args, invocationNum, fullyIdle, terminationReason, and the documented
# stdout decision object ({decision:allow|deny}, injectSteps, {}).
# The turn-end cases drive a stub bin/fm-watch-arm.sh in each scenario dir so
# arming behavior is asserted by what the guard actually invoked, never by a
# real watcher.
# All hermetic over temp dirs; no real AGY session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard-agy)
fm_git_identity fmtest fmtest@example.invalid

DENY_REASON='Hard Rule 1: Firstmate is strictly forbidden from directly editing projects/.'

# --- fixture builders --------------------------------------------------------

install_turnend_scripts() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard-agy.sh" "$dir/bin/fm-turnend-guard-agy.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
}

# The arm stub records each invocation and answers per AGY_TEST_ARM_MODE:
#   wake  - a real watcher line plus an actionable wake (default)
#   fail  - a FAILED arm verdict, the repair-nag trigger
#   clean - a started line with no wake and no healthy successor
install_arm_stub() {  # <dir>
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "${AGY_TEST_ARM_LOG:-/dev/null}"
case "${AGY_TEST_ARM_MODE:-wake}" in
  wake)
    printf 'watcher: started pid=%s (beacon fresh)\nsignal: task42\n' "$$" ;;
  fail)
    printf 'watcher: FAILED - no live watcher with a fresh beacon\n' ;;
  *)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$" ;;
esac
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

install_sessionstart_scripts() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-sessionstart-agy-nudge.sh" "$dir/bin/fm-sessionstart-agy-nudge.sh"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$dir/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$dir/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, state/,
# and the tracked scripts under bin/. Every returned path is cd-normalized so a
# TMPDIR trailing slash can never split a home string from its lock counterpart.
make_primary_dir() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  dir=$(cd "$dir" && pwd) || return 1
  printf '%s\n' "$dir"
}

# Same shape as primary, plus the .fm-secondmate-home marker so the marker
# force-include treats it as a guarded primary even as a linked worktree.
make_secondmate_dir() {  # <dir>
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'agy-sm-test\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ; no marker is present, so it must stay inert.
make_crewmate_worktree_dir() {  # <base> <dir>
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/agy-turnend-guard-test
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  dir=$(cd "$dir" && pwd) || return 1
  printf '%s\n' "$dir"
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

pid_identity() {  # <state-dir> <pid>
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$2"
}

# Record a watcher-shaped lock + fresh beacon so fm_watcher_healthy passes.
record_healthy_watcher() {  # <dir> <pid>
  local dir=$1 pid=$2 root identity
  root=$(cd "$dir" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$(cd "$dir/bin" && pwd)/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  identity=$(pid_identity "$dir/state" "$pid")
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  touch "$dir/state/.last-watcher-beat"
}

run_guard() {  # <dir> <payload> [env...]
  local dir=$1 payload=$2
  shift 2
  dir=$(cd "$dir" && pwd)
  printf '%s' "$payload" | env FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$@" bash "$dir/bin/fm-turnend-guard-agy.sh"
}

STOP_PAYLOAD='{"conversationId":"conv-1","fullyIdle":true,"terminationReason":"model_stop","executionNum":1,"workspacePaths":["/home"]}'

# --- turn-end guard: payload parsing ----------------------------------------

test_guard_empty_stdin_is_noop() {
  local dir="$TMP_ROOT/t-emptystdin"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  out=$(printf '' | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "empty stdin must exit 0"
  [ "$out" = '{}' ] || fail "empty stdin must print {}: $out"
  [ ! -e "$log" ] || fail "empty stdin must not arm"
  [ ! -e "$dir/state/.agy-turnend-epoch" ] || fail "empty stdin must not write markers"
  pass "turnend guard: empty stdin is a silent no-op"
}

test_guard_malformed_payload_is_noop() {
  local dir="$TMP_ROOT/t-malformed"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  for payload in 'not json at all' '[]' '{"conversationId":5,"fullyIdle":true}' '{"fullyIdle":"yes"}' '{'; do
    out=$(printf '%s' "$payload" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "malformed payload must exit 0: $payload"
    [ "$out" = '{}' ] || fail "malformed payload must print {}: $out"
  done
  [ ! -e "$log" ] || fail "malformed payloads must not arm"
  pass "turnend guard: malformed or mistyped payloads stand down without arming"
}

test_guard_third_party_scope_is_inert() {
  local base="$TMP_ROOT/t-inert-base" dir="$TMP_ROOT/t-inert"
  fm_git_init_commit "$base"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "inert worktree must exit 0"
  [ "$out" = '{}' ] || fail "inert worktree must print {}: $out"
  [ ! -e "$log" ] || fail "task worktree must never arm"
  [ ! -e "$dir/state/.agy-turnend-epoch" ] || fail "inert worktree must never write markers"
  pass "turnend guard: a crewmate/scout task worktree is fully inert"
}

test_guard_secondmate_home_is_a_primary() {
  local dir="$TMP_ROOT/t-secondmate"
  make_secondmate_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log" out
  : > "$dir/state/task1.meta"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "secondmate home guard must exit 0"
  assert_grep 'called' "$log" "secondmate home must arm when supervision is needed"
  assert_contains "$out" '"decision":"continue"' "a secondmate home is a guarded primary and delivers its own wake"
  pass "turnend guard: a marked secondmate home is a guarded primary"
}

test_guard_no_supervision_needed_skips_arm() {
  local dir="$TMP_ROOT/t-noneed"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "no-need guard must exit 0"
  [ "$out" = '{}' ] || fail "no-need guard must print {}: $out"
  [ ! -e "$log" ] || fail "no supervision need must not arm"
  assert_contains "$(cat "$dir/state/.agy-turnend-epoch" 2>/dev/null || true)" "outcome=no-need" "no-need must still record the Stop event"
  pass "turnend guard: an idle home records the Stop event without arming"
}

# --- turn-end guard: arming and wake delivery --------------------------------

test_guard_arms_and_delivers_wake_as_continue() {
  local dir="$TMP_ROOT/t-armwake"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=wake bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "arming guard must exit 0"
  assert_grep 'called' "$log" "supervision-needing home must invoke the arm once"
  case "$out" in
    '{"decision":"continue","reason":"'*'"}') : ;;
    *) fail "expected a continue decision object, got: $out" ;;
  esac
  assert_contains "$out" '"decision":"continue"' "wake delivery must continue the AGY loop"
  assert_contains "$out" 'signal: task42' "the wake reason line must reach the model"
  assert_contains "$out" 'FIRSTMATE_OP: v1 watcher:' "the wake must be a marked operational input"
  assert_contains "$(cat "$dir/state/.agy-turnend-epoch")" "outcome=wake" "wake delivery must record outcome=wake"
  [ ! -e "$dir/state/.agy-turnend-blocks" ] || fail "a genuine wake must reset the repair budget"
  pass "turnend guard: an actionable wake is one continue with the watcher wake in the reason"
}

test_guard_healthy_watcher_skips_arm() {
  local dir out pid
  dir=$(make_primary_dir "$TMP_ROOT/t-healthy") || fail "could not build healthy fixture"
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log" out pid
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  record_healthy_watcher "$dir" "$pid"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "healthy-watcher guard must exit 0"
  }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$out" = '{}' ] || fail "a live healthy watcher must not continue: $out"
  [ ! -e "$log" ] || fail "a live healthy watcher must not be re-armed"
  assert_contains "$(cat "$dir/state/.agy-turnend-epoch")" "outcome=healthy" "healthy watcher must record outcome=healthy"
  kill "$pid" 2>/dev/null || true
  pass "turnend guard: a live watcher with a fresh beacon is never re-armed"
}

test_guard_afk_stands_down() {
  local dir="$TMP_ROOT/t-afk"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "afk guard must exit 0"
  [ "$out" = '{}' ] || fail "away mode must never continue: $out"
  [ ! -e "$log" ] || fail "away mode daemon owns the watcher; the stop hook must not arm"
  assert_contains "$(cat "$dir/state/.agy-turnend-epoch")" "outcome=afk" "afk stand-down must record outcome=afk"
  pass "turnend guard: away mode owns the watcher and stands the stop hook down"
}

test_guard_foreign_live_lock_stands_down() {
  local dir out pid
  dir=$(make_primary_dir "$TMP_ROOT/t-foreignlock") || fail "could not build foreign-lock fixture"
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log" out pid
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  printf '%s\n' "$pid" > "$dir/state/.lock"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" bash "$dir/bin/fm-turnend-guard-agy.sh") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "foreign-lock guard must exit 0"
  }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$out" = '{}' ] || fail "a foreign session's live lock must stand the hook down: $out"
  [ ! -e "$log" ] || fail "a foreign session owns arming; this hook must not arm"
  kill "$pid" 2>/dev/null || true
  pass "turnend guard: a live lock held by another session never double-arms"
}

test_guard_dead_lock_does_not_block_arming() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/t-deadlock") || fail "could not build dead-lock fixture"
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  printf '%s\n' "$(nonexistent_pid)" > "$dir/state/.lock"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=wake bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "dead-lock guard must exit 0"
  assert_grep 'called' "$log" "a stale dead lock must not hold supervision down"
  assert_contains "$out" '"decision":"continue"' "a stale lock home must still deliver its wake"
  pass "turnend guard: a stale dead lock never blocks arming"
}

test_guard_repair_nag_is_bounded_per_conversation() {
  local dir="$TMP_ROOT/t-repair"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  local i out
  for i in 1 2 3; do
    out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=fail FM_AGY_TURNEND_ATTEMPTS=1 bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "repair nag $i must exit 0"
    assert_contains "$out" '"decision":"continue"' "repair nag $i must continue with a repair reason"
    assert_contains "$out" 'TURN WOULD END BLIND' "repair nag $i must explain the blind turn"
  done
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=fail FM_AGY_TURNEND_ATTEMPTS=1 bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "exhausted budget must exit 0"
  [ "$out" = '{}' ] || fail "the 4th consecutive failure must go silent, got: $out"
  assert_contains "$(cat "$dir/state/.agy-turnend-blocks" 2>/dev/null || true)" "count=3" "budget file must hold the bounded count"
  assert_contains "$(cat "$dir/state/.agy-turnend-epoch")" "outcome=budget-exhausted" "the silent path must record budget-exhausted"
  pass "turnend guard: the repair nag is bounded (3) per conversation, then silent"
}

test_guard_wake_resets_repair_budget() {
  local dir="$TMP_ROOT/t-budgetreset"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=fail FM_AGY_TURNEND_ATTEMPTS=1 bash "$dir/bin/fm-turnend-guard-agy.sh" >/dev/null
  printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=wake bash "$dir/bin/fm-turnend-guard-agy.sh" >/dev/null
  [ ! -e "$dir/state/.agy-turnend-blocks" ] || fail "a wake must have reset the budget file"
  out=$(printf '%s' "$STOP_PAYLOAD" | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=fail FM_AGY_TURNEND_ATTEMPTS=1 bash "$dir/bin/fm-turnend-guard-agy.sh") || fail "post-wake repair must exit 0"
  assert_contains "$out" '"decision":"continue"' "after a wake the repair budget must start fresh"
  pass "turnend guard: a genuine wake resets the bounded repair budget"
}

test_guard_records_payload_metadata() {
  local dir="$TMP_ROOT/t-meta"
  make_primary_dir "$dir" >/dev/null
  install_turnend_scripts "$dir"
  install_arm_stub "$dir"
  local log="$dir/state/arm.log"
  : > "$dir/state/task1.meta"
  printf '%s' '{"conversationId":"conv-xyz","fullyIdle":false,"terminationReason":"max_steps_exceeded"}' \
    | env FM_HOME="$dir" AGY_TEST_ARM_LOG="$log" AGY_TEST_ARM_MODE=wake bash "$dir/bin/fm-turnend-guard-agy.sh" >/dev/null
  local epoch
  epoch=$(cat "$dir/state/.agy-turnend-epoch")
  assert_contains "$epoch" "conversation=conv-xyz" "metadata marker must record the conversation id"
  assert_contains "$epoch" "termination=max_steps_exceeded" "metadata marker must record the termination reason"
  assert_contains "$epoch" "fully_idle=false" "metadata marker must record fullyIdle"
  pass "turnend guard: the epoch marker records conversationId, terminationReason, and fullyIdle"
}

# --- Hard Rule 1 PreToolUse gate ---------------------------------------------

run_hr1() {  # <dir> <payload> [env...]
  local dir=$1 payload=$2
  shift 2
  printf '%s' "$payload" | env "$@" bash "$dir/bin/fm-hardrule1-pretool-check.sh"
}

make_hr1_dir() {  # <dir>
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  mkdir -p "$dir/projects/alpha" "$dir/bin"
  cp "$ROOT/bin/fm-hardrule1-pretool-check.sh" "$dir/bin/fm-hardrule1-pretool-check.sh"
  printf '%s\n' "$dir"
}

write_tool_payload() {  # <name> <target>
  printf '{"toolCall":{"name":"%s","args":{"TargetFile":"%s"}}}\n' "$1" "$2"
}

test_hr1_denies_write_tools_into_projects() {
  local dir="$TMP_ROOT/hr1-write"
  make_hr1_dir "$dir" >/dev/null
  local out target
  target=$(cd "$dir/projects/alpha" && pwd)/f.txt
  for tool in write_to_file replace_file_content; do
    out=$(run_hr1 "$dir" "$(write_tool_payload "$tool" "$target")")
    [ "$out" = "{\"decision\":\"deny\",\"reason\":\"$DENY_REASON\"}" ] || fail "$tool: expected exact deny object, got: $out"
  done
  pass "hard rule 1: write tools targeting projects/ are denied with the exact reason"
}

test_hr1_denies_relative_targets_into_projects() {
  local dir="$TMP_ROOT/hr1-rel"
  make_hr1_dir "$dir" >/dev/null
  local out
  out=$(run_hr1 "$dir" "$(write_tool_payload write_to_file 'projects/alpha/f.txt')")
  assert_contains "$out" '"decision":"deny"' "a relative projects/ target must be denied"
  pass "hard rule 1: a relative target under projects/ is denied"
}

test_hr1_denies_multi_replace_operation_targets() {
  local dir="$TMP_ROOT/hr1-multi"
  make_hr1_dir "$dir" >/dev/null
  local target out payload
  target=$(cd "$dir/projects/alpha" && pwd)/f.txt
  payload="{\"toolCall\":{\"name\":\"multi_replace_file_content\",\"args\":{\"operations\":[{\"TargetFile\":\"$target\"}]}}}"
  out=$(run_hr1 "$dir" "$payload")
  assert_contains "$out" '"decision":"deny"' "a nested multi-edit TargetFile under projects/ must be denied"
  payload="{\"toolCall\":{\"name\":\"multi_replace_file_content\",\"args\":{\"operations\":[{\"TargetFile\":\"$dir/notes.md\"}]}}}"
  out=$(run_hr1 "$dir" "$payload")
  assert_contains "$out" '"decision":"allow"' "a multi-edit outside projects/ must be allowed"
  pass "hard rule 1: multi_replace_file_content is checked per operation target"
}

test_hr1_denies_target_aliases() {
  local dir="$TMP_ROOT/hr1-alias"
  make_hr1_dir "$dir" >/dev/null
  local target out payload
  target=$(cd "$dir/projects/alpha" && pwd)/f.txt
  for key in Filepath FilePath file_path; do
    payload="{\"toolCall\":{\"name\":\"write_to_file\",\"args\":{\"$key\":\"$target\"}}}"
    out=$(run_hr1 "$dir" "$payload")
    assert_contains "$out" '"decision":"deny"' "target key $key under projects/ must be denied"
  done
  pass "hard rule 1: Filepath/FilePath/file_path target keys are enforced"
}

test_hr1_denies_run_command_cwd_under_projects() {
  local dir="$TMP_ROOT/hr1-cwd"
  make_hr1_dir "$dir" >/dev/null
  local proj out
  proj=$(cd "$dir/projects/alpha" && pwd)
  payload="{\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git add .\",\"Cwd\":\"$proj\"}}}"
  out=$(run_hr1 "$dir" "$payload")
  assert_contains "$out" '"decision":"deny"' "a command run inside a project clone must be denied"
  payload="{\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git add .\",\"cwd\":\"$proj\"}}}"
  out=$(run_hr1 "$dir" "$payload")
  assert_contains "$out" '"decision":"deny"' "the lowercase cwd spelling must be enforced"
  pass "hard rule 1: run_command whose working directory is inside projects/ is denied"
}

test_hr1_run_command_from_home_is_allowed() {
  local dir="$TMP_ROOT/hr1-home"
  make_hr1_dir "$dir" >/dev/null
  local out
  out=$(run_hr1 "$dir" '{"toolCall":{"name":"run_command","args":{"CommandLine":"ls -la"}}}')
  assert_contains "$out" '"decision":"allow"' "a command with no cwd and no workspace defaults to the home and is allowed"
  payload="{\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"cat README.md\",\"Cwd\":\"$dir\"}}}"
  out=$(run_hr1 "$dir" "$payload")
  assert_contains "$out" '"decision":"allow"' "a command explicitly rooted in the home is allowed"
  pass "hard rule 1: run_command outside projects/ is allowed"
}

test_hr1_workspace_path_falls_back_to_cwd() {
  local dir="$TMP_ROOT/hr1-ws"
  make_hr1_dir "$dir" >/dev/null
  local proj out
  proj=$(cd "$dir/projects/alpha" && pwd)
  payload="{\"workspacePaths\":[\"$proj\"],\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"make test\"}}}"
  out=$(run_hr1 "$dir" "$payload")
  assert_contains "$out" '"decision":"deny"' "a bare command whose workspace is a project clone must be denied"
  pass "hard rule 1: workspacePaths[0] supplies the command cwd fallback"
}

test_hr1_allows_home_and_outside_targets() {
  local dir="$TMP_ROOT/hr1-allow"
  make_hr1_dir "$dir" >/dev/null
  local out
  out=$(run_hr1 "$dir" "$(write_tool_payload write_to_file "$dir/AGENTS.md")")
  assert_contains "$out" '"decision":"allow"' "writing to a home file must be allowed"
  out=$(run_hr1 "$dir" "$(write_tool_payload view_file "$dir/projects/alpha/README.md")")
  assert_contains "$out" '"decision":"allow"' "unmatched tools are allowed"
  pass "hard rule 1: home targets and unmatched tools are allowed"
}

test_hr1_path_normalization() {
  local dir="$TMP_ROOT/hr1-norm"
  make_hr1_dir "$dir" >/dev/null
  local out
  # projects/../home.txt escapes the prefix lexically and lands in the home.
  out=$(run_hr1 "$dir" "$(write_tool_payload write_to_file 'projects/../home.txt')")
  assert_contains "$out" '"decision":"allow"' "a target that normalizes outside projects/ must be allowed"
  # A child with an internal .. that stays under projects/ is still denied.
  out=$(run_hr1 "$dir" "$(write_tool_payload write_to_file 'projects/alpha/../bravo/f.txt')")
  assert_contains "$out" '"decision":"deny"' "a normalized-but-internal target under projects/ must be denied"
  pass "hard rule 1: lexical .. resolution decides the prefix membership"
}

test_hr1_no_projects_dir_is_allow() {
  local dir="$TMP_ROOT/hr1-noproj"
  make_primary_dir "$dir" >/dev/null
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-hardrule1-pretool-check.sh" "$dir/bin/fm-hardrule1-pretool-check.sh"
  local out
  out=$(run_hr1 "$dir" "$(write_tool_payload write_to_file 'projects/alpha/f.txt')")
  assert_contains "$out" '"decision":"allow"' "a checkout with no projects/ directory cannot enforce the gate and allows"
  pass "hard rule 1: an absent projects/ directory is inert (allow)"
}

test_hr1_fail_open_and_escape() {
  local dir="$TMP_ROOT/hr1-failopen"
  make_hr1_dir "$dir" >/dev/null
  local target out
  target=$(cd "$dir/projects/alpha" && pwd)/f.txt
  out=$(run_hr1 "$dir" '')
  assert_contains "$out" '"decision":"allow"' "empty stdin fails open"
  out=$(run_hr1 "$dir" 'garbage{')
  assert_contains "$out" '"decision":"allow"' "malformed JSON fails open"
  out=$(run_hr1 "$dir" "$(write_tool_payload write_to_file "$target")" FM_ALLOW_PROJECTS_WRITE=1)
  assert_contains "$out" '"decision":"allow"' "FM_ALLOW_PROJECTS_WRITE=1 is the captain-approved escape"
  pass "hard rule 1: malformed transport fails open and the approval escape allows"
}

# --- session-start PreInvocation nudge ---------------------------------------

run_nudge_adapter() {  # <dir> <payload>
  local dir=$1 payload=$2
  printf '%s' "$payload" | env FM_HOME="$dir" bash "$dir/bin/fm-sessionstart-agy-nudge.sh"
}

make_nudge_dir() {  # <dir>
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  install_sessionstart_scripts "$dir"
  printf '%s\n' "$dir"
}

test_nudge_first_invocation_injects() {
  local dir="$TMP_ROOT/n-first"
  make_nudge_dir "$dir" >/dev/null
  local out msg
  out=$(run_nudge_adapter "$dir" '{"invocationNum":0,"initialNumSteps":10}')
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].ephemeralMessage // empty' 2>/dev/null) || msg=
  [ -n "$msg" ] || fail "first invocation must inject an ephemeralMessage, got: $out"
  assert_contains "$msg" "FIRSTMATE_OP" "the injected message must be the marked operational instruction"
  assert_contains "$msg" "fm-session-start.sh" "the injected message must ask for the session-start digest"
  pass "session-start nudge: invocationNum 0 injects the marked digest instruction"
}

test_nudge_later_invocations_are_silent() {
  local dir="$TMP_ROOT/n-later"
  make_nudge_dir "$dir" >/dev/null
  local out
  for num in 1 3 20; do
    out=$(run_nudge_adapter "$dir" "{\"invocationNum\":$num}")
    [ "$out" = '{}' ] || fail "invocationNum $num must be silent, got: $out"
  done
  pass "session-start nudge: every invocation after the first is silent"
}

test_nudge_malformed_payload_is_silent() {
  local dir="$TMP_ROOT/n-malformed"
  make_nudge_dir "$dir" >/dev/null
  local out
  for payload in '' 'garbage' '{"invocationNum":"zero"}' '[]'; do
    out=$(run_nudge_adapter "$dir" "$payload")
    [ "$out" = '{}' ] || fail "malformed payload must be silent, got: $out"
  done
  pass "session-start nudge: malformed payloads never inject"
}

test_nudge_worktree_is_silent() {
  local base="$TMP_ROOT/n-inert-base" dir="$TMP_ROOT/n-inert"
  fm_git_init_commit "$base"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  install_sessionstart_scripts "$dir"
  local out
  out=$(run_nudge_adapter "$dir" '{"invocationNum":0}')
  [ "$out" = '{}' ] || fail "a task worktree must never nudge, got: $out"
  pass "session-start nudge: a crewmate/scout task worktree is silent"
}

test_nudge_lock_holding_session_is_silent() {
  local dir="$TMP_ROOT/n-lock"
  make_nudge_dir "$dir" >/dev/null
  local out
  # A lock naming the invoking shell itself is in the nudge's ancestry, so the
  # digest belongs to the running session and no nudge is owed.
  printf '%s\n' "$$" > "$dir/state/.lock"
  out=$(run_nudge_adapter "$dir" '{"invocationNum":0}')
  [ "$out" = '{}' ] || fail "a session that already holds the home lock must not be nudged, got: $out"
  pass "session-start nudge: an in-ancestry lock owner is not nudged"
}

# --- hooks.json registration --------------------------------------------------

test_hooks_json_registration_shape() {
  local hooks="$ROOT/.agents/hooks.json"
  [ -f "$hooks" ] || fail ".agents/hooks.json must exist"
  local out
  out=$(jq -e '
    (.["firstmate-turnend"].Stop | type) == "array" and
    (.["firstmate-turnend"].Stop[0].type == "command") and
    (.["firstmate-turnend"].Stop[0].command | contains("fm-turnend-guard-agy.sh")) and
    (.["firstmate-turnend"].Stop[0].timeout == 28800) and
    (.["firstmate-hardrule1"].PreToolUse | type) == "array" and
    (.["firstmate-hardrule1"].PreToolUse[0].matcher | contains("run_command")) and
    (.["firstmate-hardrule1"].PreToolUse[0].hooks[0].command | contains("fm-hardrule1-pretool-check.sh")) and
    (.["firstmate-sessionstart"].PreInvocation | type) == "array" and
    (.["firstmate-sessionstart"].PreInvocation[0].command | contains("fm-sessionstart-agy-nudge.sh"))
  ' "$hooks" 2>/dev/null) || {
    fail "hooks.json does not match the AGY registration schema: $(cat "$hooks")"
  }
  pass ".agents/hooks.json registers the three AGY hooks per the verified schema"
}

# --- shellcheck compliance -----------------------------------------------------

# bin/fm-lint.sh is the single owner of firstmate's lint definition; the
# verification contract for this phase is a clean lint of the three new scripts.
test_scripts_are_lint_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-turnend-guard-agy.sh" "$ROOT/bin/fm-hardrule1-pretool-check.sh" "$ROOT/bin/fm-sessionstart-agy-nudge.sh" 2>&1) \
    || fail "the AGY scripts are not lint-clean under the pinned definition: $out"
  pass "the three AGY scripts are clean under bin/fm-lint.sh"
}

# --- suite -------------------------------------------------------------------

test_guard_empty_stdin_is_noop
test_guard_malformed_payload_is_noop
test_guard_third_party_scope_is_inert
test_guard_secondmate_home_is_a_primary
test_guard_no_supervision_needed_skips_arm
test_guard_arms_and_delivers_wake_as_continue
test_guard_healthy_watcher_skips_arm
test_guard_afk_stands_down
test_guard_foreign_live_lock_stands_down
test_guard_dead_lock_does_not_block_arming
test_guard_repair_nag_is_bounded_per_conversation
test_guard_wake_resets_repair_budget
test_guard_records_payload_metadata
test_hr1_denies_write_tools_into_projects
test_hr1_denies_relative_targets_into_projects
test_hr1_denies_multi_replace_operation_targets
test_hr1_denies_target_aliases
test_hr1_denies_run_command_cwd_under_projects
test_hr1_run_command_from_home_is_allowed
test_hr1_workspace_path_falls_back_to_cwd
test_hr1_allows_home_and_outside_targets
test_hr1_path_normalization
test_hr1_no_projects_dir_is_allow
test_hr1_fail_open_and_escape
test_nudge_first_invocation_injects
test_nudge_later_invocations_are_silent
test_nudge_malformed_payload_is_silent
test_nudge_worktree_is_silent
test_nudge_lock_holding_session_is_silent
test_hooks_json_registration_shape
test_scripts_are_lint_clean
