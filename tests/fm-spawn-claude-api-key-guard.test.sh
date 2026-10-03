#!/usr/bin/env bash
# tests/fm-spawn-claude-api-key-guard.test.sh - every claude worker this fleet
# launches must be refused when ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN would
# reach it, unless --allow-api-key opts in or the worker-account pin shed strips
# the variable from the launch environment. On the tmux backend the check also
# covers the tmux session and global environment a new worker window inherits.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then check the exit
# code and error message for refusal or success.
#
# The remote second-mate route cannot set these variables in its pane and is
# covered by a different test surface.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-api-key-guard)

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

# install_signed_in_pin: pin the current case's claude workers to a throwaway
# root that a fake claude reports as signed in.
install_signed_in_pin() {
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/bin/sh
case "${1:-}" in
auth) printf '{\n  "status": "signed_in"\n}\n' && exit 0 ;;
*)   exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/claude"
  mkdir -p "$CASE_DIR/auth-pin"
  printf '%s\n' "$CASE_DIR/auth-pin" > "$HOME_DIR/config/claude-account"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# --- tests ------------------------------------------------------------------

# Test 1: claude spawn refuses when ANTHROPIC_API_KEY is set and no allowlist.
test_refuse_api_key_no_allowlist() {
  local rec out status
  rec=$(make_case refuse-api-key claude refuse-api-key-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn refuse-api-key-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when ANTHROPIC_API_KEY is set"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY" \
    "the refusal message should name the variable"
  pass "claude spawn refuses when ANTHROPIC_API_KEY is set and no allowlist"
}

# Test 2: claude spawn refuses when ANTHROPIC_AUTH_TOKEN is set and no allowlist.
test_refuse_auth_token_no_allowlist() {
  local rec out status
  rec=$(make_case refuse-auth-token claude refuse-auth-token-a1)
  read_case "$rec"
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-test-token \
    run_case_spawn refuse-auth-token-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when ANTHROPIC_AUTH_TOKEN is set"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN" \
    "the refusal message should name the variable"
  pass "claude spawn refuses when ANTHROPIC_AUTH_TOKEN is set and no allowlist"
}

# Test 3: claude spawn succeeds when neither variable is set.
test_succeed_unset() {
  local rec out status
  rec=$(make_case succeed-unset claude succeed-unset-a1)
  read_case "$rec"
  out=$(run_case_spawn succeed-unset-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when no API key is set"$'\n'"$out"
  pass "claude spawn succeeds when no API key is set"
}

# Test 4: claude spawn succeeds when ANTHROPIC_API_KEY is set but allowlist
# filters it out.
test_succeed_api_key_filtered_by_allowlist() {
  local rec out status
  rec=$(make_case succeed-filtered claude succeed-filtered-a1)
  read_case "$rec"
  # Write an allowlist that does NOT include ANTHROPIC_API_KEY.
  printf '%s\n' 'HOME' 'PATH' 'USER' 'LOGNAME' 'SHELL' 'TERM' 'TMPDIR' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn succeed-filtered-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when ANTHROPIC_API_KEY is filtered out by allowlist"$'\n'"$out"
  pass "claude spawn succeeds when ANTHROPIC_API_KEY is filtered out by allowlist"
}

# Test 5: claude spawn succeeds with --allow-api-key when ANTHROPIC_API_KEY is set.
test_succeed_with_allow_api_key_flag() {
  local rec out status
  rec=$(make_case succeed-allow-flag claude succeed-allow-flag-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn succeed-allow-flag-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed with --allow-api-key when ANTHROPIC_API_KEY is set"$'\n'"$out"
  assert_contains "$out" "spawned" \
    "the spawn should succeed and print the spawned line"
  pass "claude spawn succeeds with --allow-api-key flag"
}

# Test 6: non-claude harness succeeds when ANTHROPIC_API_KEY is set.
test_non_claude_harness_ignores_api_key() {
  local rec out status
  rec=$(make_case non-claude-ignores codex non-claude-ignores-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn non-claude-ignores-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "non-claude harness should succeed when ANTHROPIC_API_KEY is set"$'\n'"$out"
  pass "non-claude harness ignores ANTHROPIC_API_KEY"
}

# Test 7: claude spawn succeeds with worker-account pin when ANTHROPIC_API_KEY
# is set, because the pin shed strips it from the launch (F2).
test_succeed_with_pin_shed() {
  local rec out status
  rec=$(make_case succeed-pin-shed claude succeed-pin-shed-a1)
  read_case "$rec"
  install_signed_in_pin
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn succeed-pin-shed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed with worker-account pin when ANTHROPIC_API_KEY is set"$'\n'"$out"
  pass "claude spawn succeeds with pin shed when ANTHROPIC_API_KEY is set"
}

# Test 8: --allow-api-key is recorded in task metadata.
test_allow_api_key_recorded_in_meta() {
  local rec out status meta
  rec=$(make_case record-api-key claude record-api-key-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn record-api-key-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "spawn with --allow-api-key should succeed"$'\n'"$out"
  meta="$HOME_DIR/state/record-api-key-a1.meta"
  [ -f "$meta" ] || fail "task meta should exist after spawn"
  assert_grep 'api_key=allow' "$meta" \
    "task meta should record api_key=allow when --allow-api-key is used"
  pass "task meta records api_key=allow when --allow-api-key is used"
}

# Test 9: a key only in the tmux session environment is refused, because a new
# window in that session inherits it even though fm-spawn's own env is clean.
test_refuse_tmux_session_env() {
  local rec out status
  rec=$(make_case refuse-tmux-session claude refuse-tmux-session-a1)
  read_case "$rec"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_FAKE_TMUX_ENV_ANTHROPIC_API_KEY=sk-ant-session-key \
    run_case_spawn refuse-tmux-session-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when the tmux session environment holds ANTHROPIC_API_KEY"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY is set in the tmux session environment" \
    "the refusal should name the variable and the tmux session scope"
  assert_not_contains "$out" "sk-ant-session-key" "the refusal must not print the credential"
  pass "claude spawn refuses a key set only in the tmux session environment"
}

# Test 10: a key only in the tmux global environment is refused. A session
# lookup alone reports "unknown variable" here, yet a new window inherits the
# global value.
test_refuse_tmux_global_env() {
  local rec out status
  rec=$(make_case refuse-tmux-global claude refuse-tmux-global-a1)
  read_case "$rec"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_AUTH_TOKEN=sk-ant-global-token \
    run_case_spawn refuse-tmux-global-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when the tmux global environment holds ANTHROPIC_AUTH_TOKEN"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN is set in the tmux global environment" \
    "the refusal should name the variable and the tmux global scope"
  assert_not_contains "$out" "sk-ant-global-token" "the refusal must not print the credential"
  pass "claude spawn refuses a key set only in the tmux global environment"
}

# Test 11: a session removal marker (-NAME) wins over a global value, as it
# does for the window tmux creates.
test_succeed_tmux_session_removal_marker() {
  local rec out status
  rec=$(make_case succeed-tmux-removed claude succeed-tmux-removed-a1)
  read_case "$rec"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_FAKE_TMUX_ENV_ANTHROPIC_API_KEY=- \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-global-key \
    run_case_spawn succeed-tmux-removed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when the tmux session removes the global key"$'\n'"$out"
  pass "claude spawn honors a tmux session removal marker over a global key"
}

# Test 12: a tmux-environment key does not refuse when the worker-account pin
# shed strips it from the launch.
test_succeed_tmux_env_with_pin_shed() {
  local rec out status
  rec=$(make_case succeed-tmux-pin claude succeed-tmux-pin-a1)
  read_case "$rec"
  install_signed_in_pin
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_FAKE_TMUX_ENV_ANTHROPIC_API_KEY=sk-ant-session-key \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_AUTH_TOKEN=sk-ant-global-token \
    run_case_spawn succeed-tmux-pin-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed with a pin when only the tmux environment holds a key"$'\n'"$out"
  pass "claude spawn succeeds with pin shed when the tmux environment holds a key"
}

# Test 13: a tmux-environment key the allowlist does not list is filtered out
# of the launch, so it does not refuse; a listed one does.
test_tmux_env_follows_the_allowlist() {
  local rec out status
  rec=$(make_case tmux-allowlist claude tmux-allowlist-a1 tmux-allowlist-a2)
  read_case "$rec"
  printf '%s\n' 'HOME' 'PATH' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-global-key \
    run_case_spawn tmux-allowlist-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when the allowlist filters out the tmux key"$'\n'"$out"
  printf '%s\n' 'HOME' 'PATH' 'ANTHROPIC_API_KEY' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-global-key \
    run_case_spawn tmux-allowlist-a2 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when the allowlist forwards the tmux key"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY is set in the tmux global environment" \
    "the refusal should name the forwarded variable"
  pass "claude spawn tmux-environment check follows config/launch-env-allowlist"
}

# --- run --------------------------------------------------------------------

test_refuse_api_key_no_allowlist
test_refuse_auth_token_no_allowlist
test_succeed_unset
test_succeed_api_key_filtered_by_allowlist
test_succeed_with_allow_api_key_flag
test_non_claude_harness_ignores_api_key
test_succeed_with_pin_shed
test_allow_api_key_recorded_in_meta
test_refuse_tmux_session_env
test_refuse_tmux_global_env
test_succeed_tmux_session_removal_marker
test_succeed_tmux_env_with_pin_shed
test_tmux_env_follows_the_allowlist
