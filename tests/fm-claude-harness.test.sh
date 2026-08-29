#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn.sh's claude-specific workspace-trust
# handling (task fm-claude-trust-dialog-autoaccept). The classifier shape
# itself is pinned in tests/fm-composer-lib.test.sh; this file pins the
# spawn-path behavior that drives it: detect, navigate, verify, or fail loudly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A suite run from inside Claude, Cursor, Pi, or Grok inherits their env
# markers; drop them so fm-harness.sh's crew-default resolution never leaks in.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

trap 'rm -rf "$TMP_ROOT"' EXIT

# make_spawn_fakebin: a fake tmux modeling Claude Code's own workspace-trust
# dialog as a small state machine, driven entirely by the exact tmux calls
# bin/fm-spawn.sh issues (send-keys -l for the launch command, then bare
# Down/Enter key sends, then capture-pane reads). FM_FAKE_CLAUDE_MODE selects
# which real-world scenario the fixture plays:
#   trusted       (default posture for a plain spawn) the repository is
#                 already trusted - no dialog ever appears.
#   dialog        a never-trusted repository shows the dialog, cancel-focused
#                 by default; Down then Enter accepts it and claude resumes
#                 processing the launch brief.
#   stuck-dialog  Down never moves the highlight off "No, exit" (simulates a
#                 future rendering drift) - the dialog can never be cleared.
#   no-processing accepting the dialog clears it, but claude never shows a
#                 busy signal afterward (simulates a worker that quietly
#                 re-parked on a second gate instead of resuming).
#   delayed-dialog the shell remains visible for two reads before the dialog.
#   stale-no-processing an old busy footer remains in scrollback after trust.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
state=$(cat "$FM_FAKE_CLAUDE_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    trust-no)
      printf ' Accessing workspace:\n\n %s\n\n Quick safety check: is this yours?\n\n \xe2\x9d\xaf No, exit\n   Yes, I trust this folder\n\n Enter to confirm . Esc to cancel\n' "${FM_FAKE_PANE_PATH:-}"
      ;;
    trust-yes)
      printf ' Accessing workspace:\n\n %s\n\n Quick safety check: is this yours?\n\n   No, exit\n \xe2\x9d\xaf Yes, I trust this folder\n\n Enter to confirm . Esc to cancel\n' "${FM_FAKE_PANE_PATH:-}"
      ;;
    processing)
      printf 'Thinking... (esc to interrupt)\n'
      ;;
    gone-stuck)
      printf '\xe2\x9d\xaf \n'
      ;;
    gone-stale)
      printf 'Thinking... (esc to interrupt)\ncurrent row 01\ncurrent row 02\ncurrent row 03\ncurrent row 04\ncurrent row 05\ncurrent row 06\ncurrent row 07\ncurrent row 08\ncurrent row 09\ncurrent row 10\ncurrent row 11\ncurrent row 12\n$ \n'
      ;;
    *)
      case "${FM_FAKE_CLAUDE_MODE:-trusted}" in
        stale-no-processing) printf 'Thinking... (esc to interrupt)\nshell starting\n$ \n' ;;
        *) printf 'shell starting\n$ \n' ;;
      esac
      ;;
  esac
}
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *'claude --dangerously-skip-permissions'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'command-typed\n' > "$FM_FAKE_CLAUDE_STATE"
          ;;
      esac
      exit 0
    fi
    printf '%s\n' "$*" >> "$FM_FAKE_KEY_LOG"
    case " $* " in
      *' Down '*)
        if [ "$state" = trust-no ] && [ "${FM_FAKE_CLAUDE_MODE:-trusted}" != stuck-dialog ]; then
          printf 'trust-yes\n' > "$FM_FAKE_CLAUDE_STATE"
        fi
        ;;
      *' Enter '*)
        case "$state" in
          command-typed)
            case "${FM_FAKE_CLAUDE_MODE:-trusted}" in
              trusted) printf 'processing\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              delayed-dialog) printf 'delayed-1\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              *) printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE" ;;
            esac
            ;;
          trust-yes)
            case "${FM_FAKE_CLAUDE_MODE:-trusted}" in
              no-processing) printf 'gone-stuck\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              stale-no-processing) printf 'gone-stale\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              *) printf 'processing\n' > "$FM_FAKE_CLAUDE_STATE" ;;
            esac
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    case "$state" in
      delayed-1) state=delayed-2; printf 'delayed-2\n' > "$FM_FAKE_CLAUDE_STATE" ;;
      delayed-2) state=trust-no; printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE" ;;
    esac
    fake_screen
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for claude\n' > "$home/data/$id/brief.md"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/keys.log"
  : > "$case_dir/claude.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_KEY_LOG="$case_dir/keys.log" \
    FM_FAKE_CLAUDE_STATE="$case_dir/claude.state" \
    FM_FAKE_CLAUDE_MODE="${FM_FAKE_CLAUDE_MODE:-trusted}" \
    FM_CLAUDE_TRUST_POLLS=10 FM_CLAUDE_TRUST_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness claude --mode no-mistakes --yolo off "$@" 2>&1
}

test_claude_already_trusted_spawn_never_touches_the_dialog() {
  local id rec out rc
  id="claude-trusted-z1-$$"
  rec=$(make_spawn_case trusted "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=trusted run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an already-trusted claude spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude" "claude spawn did not report success"
  assert_not_contains "$(cat "$CASE_DIR/keys.log")" "Down" \
    "an already-trusted spawn navigated a dialog that was never showing"
  pass "fm-spawn: an already-trusted claude spawn skips all dialog handling"
}

test_claude_trust_dialog_is_navigated_never_a_blind_enter() {
  local id rec out rc keys bare_keys
  id="claude-dialog-z2-$$"
  rec=$(make_spawn_case dialog "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=dialog run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a claude spawn that clears the trust dialog should succeed"
  assert_contains "$out" "spawned $id harness=claude" "claude spawn did not report success after accepting trust"
  keys=$(cat "$CASE_DIR/keys.log")
  assert_contains "$keys" "Down" "accepting the trust dialog must navigate off the cancel-focused default"
  # Isolate the bare single-key sends (exactly "send-keys -t <target> <key>",
  # 4 fields) from the earlier bundled "treehouse get"/GOTMPDIR lines, which
  # also end in the word "Enter" but are not dialog navigation. The correct
  # sequence is exactly: Enter (submits the launch command, revealing the
  # dialog), Down (off the cancel-focused default), Enter (accepts "Yes") -
  # never two Enters back to back, which would mean a blind Enter was sent
  # while "No, exit" was still focused.
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = "$(printf 'Enter\nDown\nEnter')" ] \
    || fail "the dialog navigation sequence was not exactly Enter, Down, Enter - got: $bare_keys"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] || fail "the dialog must end with claude actually processing the brief"
  pass "fm-spawn: claude's trust dialog is navigated to \"Yes\" before Enter, never a blind Enter"
}

test_claude_stuck_dialog_fails_loudly() {
  local id rec out rc
  id="claude-stuck-z3-$$"
  rec=$(make_spawn_case stuck "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=stuck-dialog run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a trust dialog that never clears should fail the spawn"
  assert_contains "$out" "claude's workspace-trust dialog could not be cleared" \
    "a stuck trust dialog lacked a loud diagnostic"
  assert_grep "failed: claude's workspace-trust dialog could not be cleared" "$HOME_DIR/state/$id.status" \
    "a stuck trust dialog did not leave a supervisor-visible failure"
  pass "fm-spawn: a trust dialog that never clears fails loudly instead of leaving a silent idle pane"
}

test_claude_accept_without_processing_fails_loudly() {
  local id rec out rc
  id="claude-noproc-z4-$$"
  rec=$(make_spawn_case noproc "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=no-processing run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "accepting the dialog without a confirmed resumed brief should fail"
  assert_contains "$out" "never confirmed it started processing the launch brief" \
    "an unconfirmed post-accept resume lacked a loud diagnostic"
  assert_grep "failed: claude accepted the workspace-trust dialog but never confirmed it started processing the launch brief" \
    "$HOME_DIR/state/$id.status" \
    "an unconfirmed post-accept resume did not leave a supervisor-visible failure"
  pass "fm-spawn: accepting the dialog is not proof of delivery - an unconfirmed resume still fails loudly"
}

test_claude_delayed_trust_dialog_is_not_missed() {
  local id rec out rc
  id="claude-delayed-z5-$$"
  rec=$(make_spawn_case delayed "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=delayed-dialog run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a delayed trust dialog should still be cleared"
  assert_contains "$(cat "$CASE_DIR/keys.log")" "Down" \
    "a delayed trust dialog was mistaken for an already-trusted launch"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] \
    || fail "the delayed dialog spawn did not reach brief processing"
  pass "fm-spawn: a delayed Claude trust dialog remains inside the launch observation window"
}

test_claude_stale_busy_scrollback_cannot_confirm_processing() {
  local id rec out rc
  id="claude-stale-z6-$$"
  rec=$(make_spawn_case stale "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=stale-no-processing run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "stale busy scrollback must not confirm the new launch"
  assert_contains "$out" "never confirmed it started processing the launch brief" \
    "stale busy scrollback did not produce the processing failure"
  pass "fm-spawn: stale busy scrollback cannot prove a replacement Claude launch started"
}

test_claude_already_trusted_spawn_never_touches_the_dialog
test_claude_trust_dialog_is_navigated_never_a_blind_enter
test_claude_stuck_dialog_fails_loudly
test_claude_accept_without_processing_fails_loudly
test_claude_delayed_trust_dialog_is_not_missed
test_claude_stale_busy_scrollback_cannot_confirm_processing
