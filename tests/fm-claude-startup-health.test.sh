#!/usr/bin/env bash
# Regression tests for bin/fm-spawn.sh's claude_wait_for_working post-launch
# health gate.
#
# Claude's trust pre-registration (bin/fm-claude-trust.sh, tested separately in
# tests/fm-claude-trust.test.sh) only removes the workspace-trust and
# external-imports dialogs when it can prove the launch target is a genuine
# isolated worktree or a seeded secondmate home. A worker whose pane still
# meets one of those dialogs anyway - or a stale/expired credential - used to
# sit there indefinitely, with nothing shorter than a much slower stale-wake
# heuristic to catch it: kimi, rovo, and agy each got a post-launch
# confirmation gate when they were wired up, but claude never did. This suite
# pins the gate that closes that gap:
#   1. A pane showing none of the three known blocking renders passes within
#      the short bounded settle window (no positive "it's working" proof is
#      required - see the block comment above claude_wait_for_working in
#      bin/fm-spawn.sh for why that would be the wrong shape here).
#   2. A pane showing the workspace-trust dialog title fails the spawn with
#      that concrete reason and closes the endpoint it just launched.
#   3. A pane showing the external-imports dialog title fails the same way.
#   4. A pane reporting "Login expired" fails the same way.
#   5. The settle window is bounded: a stuck pane fails within a few polls
#      rather than the harness's own inactivity timeouts.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-startup-health)

# make_claude_health_fakebin <dir> builds a fake tmux whose capture-pane
# renders FM_FAKE_CLAUDE_SCREEN verbatim (empty by default - an ordinary
# working pane) and a no-op claude binary that must never actually run (the
# gate only ever inspects the pane the fake tmux renders, never execs the
# adapter itself).
make_claude_health_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_CALL_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys) exit 0 ;;
  capture-pane) printf '%s' "${FM_FAKE_CLAUDE_SCREEN:-}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
echo "fake claude must never execute; the gate inspects the pane the fake tmux renders" >&2
exit 9
SH
  chmod +x "$fakebin/claude"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_claude_health_case() {  # <name> <id> -> "<case>|<home>|<proj>|<wt>|<fakebin>"
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_claude_health_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id" "Exercise the claude startup health gate for $id."
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_claude_health_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_claude_health_spawn() {  # <id> [screen]
  local id=$1 screen=${2:-}
  local spawn_home="$HOME_DIR/user-home"
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$spawn_home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" FM_FAKE_CLAUDE_SCREEN="$screen" \
    FM_CLAUDE_READY_POLLS="${FM_CLAUDE_READY_POLLS:-4}" FM_CLAUDE_POLL_INTERVAL=0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_ordinary_pane_passes_within_the_settle_window() {
  local id rec out rc
  id="claude-health-ok-z1-$$"
  rec=$(make_claude_health_case ok "$id")
  read_claude_health_case "$rec"
  out=$(run_claude_health_spawn "$id" '')
  rc=$?
  expect_code 0 "$rc" "an ordinary claude pane should pass the startup health gate"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report success"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful spawn must never tear down the endpoint it just launched"
  pass "fm-spawn: an ordinary claude pane passes the startup health gate"
}

test_workspace_trust_dialog_fails_the_spawn_and_closes_the_endpoint() {
  local id rec out rc
  id="claude-health-trust-z2-$$"
  rec=$(make_claude_health_case trust "$id")
  read_claude_health_case "$rec"
  out=$(run_claude_health_spawn "$id" \
    'Quick safety check: Is this a project you created or one you trust?')
  rc=$?
  [ "$rc" -ne 0 ] || fail "a pane showing the workspace-trust dialog must fail the spawn"$'\n'"$out"
  assert_contains "$out" "the workspace-trust dialog is showing, so pre-registration did not take effect" \
    "the failure did not name the workspace-trust dialog"
  assert_not_contains "$out" "spawned $id" "a trust-dialog-blocked spawn still reported success"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed health gate left its launched endpoint running"
  assert_grep 'failed: the workspace-trust dialog is showing' "$HOME_DIR/state/$id.status" \
    "the failed health gate did not record the failure in the task status"
  pass "fm-spawn: a stuck workspace-trust dialog fails the spawn and closes the endpoint"
}

test_external_imports_dialog_fails_the_spawn() {
  local id rec out rc
  id="claude-health-imports-z3-$$"
  rec=$(make_claude_health_case imports "$id")
  read_claude_health_case "$rec"
  out=$(run_claude_health_spawn "$id" 'Allow external CLAUDE.md file imports?')
  rc=$?
  [ "$rc" -ne 0 ] || fail "a pane showing the external-imports dialog must fail the spawn"$'\n'"$out"
  assert_contains "$out" "the external CLAUDE.md imports dialog is showing" \
    "the failure did not name the external-imports dialog"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed health gate left its launched endpoint running"
  pass "fm-spawn: a stuck external-imports dialog fails the spawn and closes the endpoint"
}

test_login_expired_fails_the_spawn() {
  local id rec out rc
  id="claude-health-login-z4-$$"
  rec=$(make_claude_health_case login "$id")
  read_claude_health_case "$rec"
  out=$(run_claude_health_spawn "$id" $'stale plaintext credential\nLogin expired\n')
  rc=$?
  [ "$rc" -ne 0 ] || fail "a pane reporting Login expired must fail the spawn"$'\n'"$out"
  assert_contains "$out" 'claude reports "Login expired"' \
    "the failure did not name the expired-credential reason"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed health gate left its launched endpoint running"
  pass "fm-spawn: an expired-credential pane fails the spawn and closes the endpoint"
}

test_settle_window_is_bounded() {
  local id rec out rc started elapsed
  id="claude-health-stuck-z5-$$"
  rec=$(make_claude_health_case stuck "$id")
  read_claude_health_case "$rec"
  started=$(date +%s)
  out=$(FM_CLAUDE_READY_POLLS=3 run_claude_health_spawn "$id" \
    'Quick safety check: Is this a project you created or one you trust?')
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 0 ] || fail "a stuck trust dialog must fail rather than time out silently into success"
  [ "$elapsed" -lt 15 ] || fail "the health gate did not stay bounded (took ${elapsed}s)"
  assert_contains "$out" "the workspace-trust dialog is showing" \
    "a bounded failure lost its concrete reason"
  pass "fm-spawn: the claude startup health gate stays bounded instead of waiting indefinitely"
}

test_ordinary_pane_passes_within_the_settle_window
test_workspace_trust_dialog_fails_the_spawn_and_closes_the_endpoint
test_external_imports_dialog_fails_the_spawn
test_login_expired_fails_the_spawn
test_settle_window_is_bounded

echo "# all fm-claude-startup-health tests passed"
