#!/usr/bin/env bash
# Behavior tests for fm-spawn's non-blocking, post-launch autonomy observation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-autonomy)

cleanup_autonomy_tests() {
  rm -rf "/tmp/fm-autonomy-healthy-$$" "/tmp/fm-autonomy-auto-$$" \
    "/tmp/fm-autonomy-manual-$$" "/tmp/fm-autonomy-unverified-$$" \
    "/tmp/fm-autonomy-codex-$$"
  fm_test_cleanup
}
trap cleanup_autonomy_tests EXIT

make_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  list-windows|has-session|new-session|set-window-option|send-keys|kill-window) ;;
  new-window) printf '%s\n' %1 ;;
  capture-pane) printf '%s\n' "$FM_FAKE_PANE_CAPTURE" ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude codex gh gh-axi sleep
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 dir home project worktree fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  fakebin=$(make_fakebin "$dir")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  printf '%s\n' "$home|$project|$worktree|$fakebin"
}

run_spawn() {  # <home> <project> <worktree> <fakebin> <capture> <id> <harness>
  local home=$1 project=$2 worktree=$3 fakebin=$4 capture=$5 id=$6 harness=$7
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" \
    FM_FAKE_PANE_CAPTURE="$capture" FM_SPAWN_AUTONOMY_POLLS=1 \
    FM_SPAWN_AUTONOMY_POLL_INTERVAL=0 TMUX='fake,1,0' \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$project" --harness "$harness" 2>&1
}

test_verified_claude_bypass_is_accepted() {
  local id="autonomy-healthy-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case healthy claude "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" \
    '⏵⏵ bypass permissions on (shift+tab to cycle)' "$id" claude) || rc=$?
  expect_code 0 "$rc" "a verified Claude bypass launch must stay healthy"
  assert_contains "$out" "spawned $id harness=claude" \
    "healthy Claude autonomy observation blocked spawn completion"
  assert_not_contains "$out" "AUTONOMY WARNING" \
    "verified Claude bypass mode produced a false warning"
  pass "fm-spawn: Claude's verified bypass footer satisfies the autonomy postcondition"
}

test_verified_claude_downgrades_warn_without_blocking() {
  local mode id rec home project worktree fakebin capture out rc
  for mode in auto manual; do
    id="autonomy-$mode-$$"
    rec=$(make_case "$mode" claude "$id")
    IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
    capture="Bypass permissions mode was disabled by settings
⏵⏵ $mode mode on (shift+tab to cycle)"
    rc=0
    out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" "$capture" "$id" claude) || rc=$?
    expect_code 0 "$rc" "a Claude $mode downgrade warning must not block the worker"
    assert_contains "$out" "AUTONOMY WARNING: task $id requested mode=bypassPermissions but observed mode=$mode" \
      "Claude $mode downgrade warning omitted requested or observed mode"
    assert_contains "$out" 'permissions.disableBypassPermissionsMode is "disable"' \
      "Claude $mode downgrade warning omitted the likely setting cause"
    assert_contains "$out" "The worker remains launched" \
      "Claude $mode downgrade warning did not preserve the warning-only boundary"
    assert_contains "$out" "spawned $id harness=claude" \
      "Claude $mode downgrade stopped an otherwise healthy spawn"
  done
  pass "fm-spawn: verified Claude auto/manual downgrades warn with cause and remain non-blocking"
}

test_unverified_claude_mode_warns_without_blocking() {
  local id="autonomy-unverified-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case unverified claude "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" '' "$id" claude) || rc=$?
  expect_code 0 "$rc" "an unverified Claude mode warning must not block the worker"
  assert_contains "$out" "AUTONOMY WARNING: task $id requested mode=bypassPermissions but observed mode=unverified" \
    "missing Claude mode signal degraded silently"
  assert_contains "$out" "worker UI did not render a verified status footer in time or the backend capture was unavailable" \
    "unverified Claude warning omitted its likely causes"
  assert_contains "$out" "The worker remains launched" \
    "unverified Claude warning did not preserve the warning-only boundary"
  assert_contains "$out" "spawned $id harness=claude" \
    "unverified Claude mode observation blocked an otherwise healthy spawn"
  pass "fm-spawn: a missing Claude mode postcondition warns loudly without blocking"
}

test_unverified_codex_rendering_is_not_guessed() {
  local id="autonomy-codex-$$" rec home project worktree fakebin out rc=0
  rec=$(make_case codex codex "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$project" "$worktree" "$fakebin" \
    'auto mode on' "$id" codex) || rc=$?
  expect_code 0 "$rc" "Codex spawn must remain unchanged without a verified mode signal"
  assert_not_contains "$out" "AUTONOMY WARNING" \
    "fm-spawn guessed a Codex mode from Claude-specific text"
  assert_contains "$out" "spawned $id harness=codex" \
    "unverified Codex mode observation blocked spawn completion"
  pass "fm-spawn: adapters without a verified mode rendering are deliberately left alone"
}

test_verified_claude_bypass_is_accepted
test_verified_claude_downgrades_warn_without_blocking
test_unverified_claude_mode_warns_without_blocking
test_unverified_codex_rendering_is_not_guessed
