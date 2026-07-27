#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI crewmate/scout adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      [ "$prev" = -l ] && printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
      prev=$arg
    done
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse agy
  mkdir -p "$fakebin/base"
  for tool in bash git grep sed tr mkdir mktemp sleep realpath readlink sort cut tail cat rm touch date seq awk dirname basename uname; do
    ln -s "$(command -v "$tool")" "$fakebin/base/$tool"
  done
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 dir home project worktree fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'agy\n' > "$home/config/crew-harness"
  printf 'brief for AGY\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$dir/launch.log"
  printf '%s|%s|%s|%s|%s\n' "$dir" "$home" "$project" "$worktree" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WORKTREE_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --harness agy "${@:2}" 2>&1
}

test_agy_launch_threads_only_supported_profile_axes() {
  local id=agy-profile-z1 rec out status launch
  rec=$(make_case profile "$id")
  read_case "$rec"
  out=$(run_spawn "$id" --model gemini-3.6-flash-high --effort high)
  status=$?
  expect_code 0 "$status" "AGY spawn with accepted profile axes should succeed"
  assert_contains "$out" "spawned $id harness=agy" "AGY spawn did not report its harness"
  assert_grep 'model=gemini-3.6-flash-high' "$HOME_DIR/state/$id.meta" "AGY metadata lost its model"
  assert_grep 'effort=high' "$HOME_DIR/state/$id.meta" "AGY metadata lost its effort"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "'$FAKEBIN_DIR/agy' --dangerously-skip-permissions --mode accept-edits --model 'gemini-3.6-flash-high' --effort 'high' --prompt-interactive" "AGY launch flags are incomplete"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" "AGY launch lost the canonical encoded brief"
  pass "fm-spawn: AGY launches autonomously with model, accepted effort, and encoded brief"
}

test_agy_omits_unsupported_effort() {
  local id=agy-max-z2 rec out status launch
  rec=$(make_case max "$id")
  read_case "$rec"
  out=$(run_spawn "$id" --effort max)
  status=$?
  expect_code 0 "$status" "AGY spawn with unsupported effort should retain metadata and launch"
  assert_grep 'effort=max' "$HOME_DIR/state/$id.meta" "AGY metadata lost unsupported requested effort"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" '--effort' "AGY launch passed an unsupported effort"
  pass "fm-spawn: AGY omits unsupported effort values"
}

test_agy_missing_binary_refuses_before_pane_creation() {
  local id=agy-missing-z3 rec out status
  rec=$(make_case missing "$id")
  read_case "$rec"
  # shellcheck disable=SC2329 # Exported and invoked by the spawned subprocess's PATH lookup.
  agy() { :; }
  export -f agy
  out=$(run_spawn "$id")
  status=$?
  unset -f agy
  [ "$status" -ne 0 ] || fail "AGY spawn without its binary should refuse"
  assert_contains "$out" 'agy executable not found in PATH' "AGY missing-binary refusal lacked its cause"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "AGY missing-binary refusal sent a launch command"
  pass "fm-spawn: AGY missing binary refuses before launch"
}

test_agy_marker_detection_and_secondmate_refusal() {
  local out rec id=agy-secondmate-z4 status
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT ANTIGRAVITY_AGENT=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "AGY marker detection returned '$out'"
  rec=$(make_case secondmate "$id")
  read_case "$rec"
  status=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" "$SPAWN" "$id" "$HOME_DIR" --secondmate 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "AGY secondmate launch should refuse"
  assert_contains "$out" 'not secondmates' "AGY secondmate refusal lacked its scope"
  pass "fm-harness: AGY marker is recognized while secondmate launch remains refused"
}

test_agy_busy_and_composer_signatures_are_scoped() {
  local capture out
  capture="$TMP_ROOT/pane"
  printf 'esc to cancel generation\n' > "$capture"
  # shellcheck disable=SC2329 # Invoked by the sourced tmux-lib helpers, not directly here.
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      display-message) printf '2\n' ;;
    esac
  }
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  fm_pane_is_busy fake agy || fail "AGY cancel footer was not busy"
  if fm_pane_is_busy fake codex; then
    fail "AGY cancel footer leaked into Codex busy detection"
  fi
  printf '────────────────\n> \033[90mAccept-edits mode: file edits auto-approved (shift+tab to cycle)\033[0m\n────────────────\n? for shortcuts\n' > "$capture"
  out=$(fm_tmux_composer_state fake agy)
  [ "$out" = empty ] || fail "AGY separator composer should be empty, got '$out'"
  out=$(fm_tmux_composer_state fake codex)
  [ "$out" != empty ] || fail "AGY separator composer leaked into Codex classification"
  pass "tmux: AGY busy and accept-edits composer signatures stay harness-scoped"
}

test_agy_tmux_submit_and_key_steering() {
  local mode=empty out
  tmux() {
    case "${1:-}" in
      display-message) printf '2\n' ;;
      capture-pane)
        case "$mode" in
          empty) printf '────────────────\n> \033[90mAccept-edits mode: file edits auto-approved\033[0m\n────────────────\n' ;;
          pending) printf '────────────────\n> steer\n────────────────\n' ;;
        esac
        ;;
      send-keys)
        case " $* " in
          *' -l '*) mode=pending ;;
          *' Enter '*) mode=empty ;;
          *' Escape'*) : ;;
        esac
        ;;
    esac
  }
  # shellcheck disable=SC2034 # Consumed by tmux.sh's own sourcing of fm-tmux-lib.sh, not by this test.
  FM_BACKEND_LIB_DIR="$ROOT/bin"
  # shellcheck source=/dev/null
  . "$ROOT/bin/backends/tmux.sh"
  out=$(fm_backend_tmux_send_text_submit fake steer 1 0 0 ignored agy)
  [ "$out" = empty ] || fail "AGY text steer was not confirmed, got '$out'"
  fm_backend_tmux_send_key fake Escape || fail "AGY interrupt key was rejected"
  pass "tmux: AGY text submission and Escape steering use the shared backend primitives"
}

test_agy_herdr_composer_uses_recorded_harness() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/backends/herdr.sh"
  # shellcheck disable=SC2034 # Consumed by fm_backend_herdr_composer_state after this override runs.
  fm_backend_herdr_parse_target() { FM_BACKEND_HERDR_SESSION=s; FM_BACKEND_HERDR_PANE=p; }
  fm_backend_herdr_capture_ansi() { printf '────────────────\n> \033[90mAccept-edits mode: file edits auto-approved (shift+tab to cycle)\033[0m\n────────────────\n'; }
  out=$(fm_backend_herdr_composer_state s:p agy)
  [ "$out" = empty ] || fail "AGY Herdr composer should be empty, got '$out'"
  out=$(fm_backend_herdr_composer_state s:p codex)
  [ "$out" = unknown ] || fail "AGY Herdr composer leaked into Codex classification, got '$out'"
  pass "Herdr: AGY separator composer applies only to recorded AGY tasks"
}

test_agy_launch_threads_only_supported_profile_axes
test_agy_omits_unsupported_effort
test_agy_missing_binary_refuses_before_pane_creation
test_agy_marker_detection_and_secondmate_refusal
test_agy_busy_and_composer_signatures_are_scoped
test_agy_tmux_submit_and_key_steering
test_agy_herdr_composer_uses_recorded_harness
