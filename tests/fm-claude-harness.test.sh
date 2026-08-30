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
NODE_BIN=$(command -v node) || fail "node is required for the Orca Claude spawn fixture"
NODE_BIN_DIR=${NODE_BIN%/*}

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
#   focused-dialog the same dialog already has the trust option focused;
#                 Enter accepts it without an unnecessary Down key.
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
    trust-yes|trust-yes-stale)
      printf ' Accessing workspace:\n\n %s\n\n Quick safety check: is this yours?\n\n   No, exit\n \xe2\x9d\xaf Yes, I trust this folder\n\n Enter to confirm . Esc to cancel\n' "${FM_FAKE_PANE_PATH:-}"
      ;;
    processing)
      printf 'Thinking... (esc to interrupt)\n'
      ;;
    trusted-idle)
      printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\302\240\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n'
      ;;
    blank-2)
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
  display-message)
    case "$*" in
      *'#{cursor_y}'*) [ "$state" = trusted-idle ] && printf '1\n' || printf '0\n' ;;
      *'#{pane_id}'*) printf '%%1\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
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
        if [ "$state" = trust-no ]; then
          case "${FM_FAKE_CLAUDE_MODE:-trusted}" in
            busy-after-down) printf 'processing\n' > "$FM_FAKE_CLAUDE_STATE" ;;
            disappears-after-down) printf 'gone-stuck\n' > "$FM_FAKE_CLAUDE_STATE" ;;
            stuck-dialog) ;;
            *) printf 'trust-yes\n' > "$FM_FAKE_CLAUDE_STATE" ;;
          esac
        fi
        ;;
      *' Enter '*)
        case "$state" in
          command-typed)
            case "${FM_FAKE_CLAUDE_MODE:-trusted}" in
              trusted) printf 'processing\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              trusted-idle) printf 'trusted-idle\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              focused-dialog) printf 'trust-yes\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              delayed-dialog) printf 'delayed-1\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              blank-delayed-dialog) printf 'blank-1\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              last-poll-dialog) printf 'last-1\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              stale-dialog) printf 'processing\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              *) printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE" ;;
            esac
            ;;
          trust-yes)
            case "${FM_FAKE_CLAUDE_MODE:-trusted}" in
              no-processing) printf 'gone-stuck\n' > "$FM_FAKE_CLAUDE_STATE" ;;
              slow-accept-repaint) printf 'trust-yes-stale\n' > "$FM_FAKE_CLAUDE_STATE" ;;
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
    if [ "${FM_FAKE_CLAUDE_MODE:-trusted}" = unreadable ]; then
      exit 1
    fi
    if [ "${FM_FAKE_CLAUDE_MODE:-trusted}" = dialog-baseline-failed ] && [ -z "$state" ]; then
      exit 1
    fi
    case "$state" in
      blank-1) state=blank-2; printf 'blank-2\n' > "$FM_FAKE_CLAUDE_STATE" ;;
      blank-2) state=trust-no; printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE" ;;
      delayed-1) state=delayed-2; printf 'delayed-2\n' > "$FM_FAKE_CLAUDE_STATE" ;;
      delayed-2) state=trust-no; printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE" ;;
      last-1) state=last-2; printf 'last-2\n' > "$FM_FAKE_CLAUDE_STATE" ;;
      last-2) state=trust-no; printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE" ;;
    esac
    if [ "${FM_FAKE_CLAUDE_MODE:-trusted}" = stale-dialog ] && [[ " $* " = *' -S '* ]]; then
      printf ' Accessing workspace:\n\n /old/repo\n\n \xe2\x9d\xaf No, exit\n   Yes, I trust this folder\n\n Enter to confirm . Esc to cancel\nThinking... (esc to interrupt)\n'
      exit 0
    fi
    if [ "$state" = trust-yes-stale ]; then
      fake_screen
      printf 'processing\n' > "$FM_FAKE_CLAUDE_STATE"
      exit 0
    fi
    fake_screen
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_ORCA_LOG"
state=$(cat "$FM_FAKE_CLAUDE_STATE" 2>/dev/null || true)
case "${1:-}:${2:-}" in
  status:*)
    printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
    ;;
  repo:show)
    printf '%s\n' '{"ok":true,"result":{"repo":{"id":"repo-1"}}}'
    ;;
  worktree:create)
    printf '{"ok":true,"result":{"worktree":{"id":"wt-1","path":"%s"},"terminal":{"handle":"term-1"}}}\n' "$FM_FAKE_ORCA_WT"
    ;;
  terminal:send)
    text_arg=
    enter=0
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --text)
          shift
          text_arg=${1:-}
          ;;
        --enter) enter=1 ;;
      esac
      shift
    done
    case "$text_arg" in
      *'claude --dangerously-skip-permissions'*)
        printf 'command-typed\n' > "$FM_FAKE_CLAUDE_STATE"
        state=command-typed
        ;;
    esac
    if [ "$enter" = 1 ] && [ -z "$text_arg" ] && [ "$state" = command-typed ]; then
      printf 'trust-no\n' > "$FM_FAKE_CLAUDE_STATE"
    fi
    printf '%s\n' '{"ok":true,"result":{}}'
    ;;
  terminal:read)
    case "$state" in
      trust-no)
        printf '{"ok":true,"result":{"terminal":{"tail":[" Accessing workspace:",""," %s",""," Quick safety check: is this yours?",""," ❯ No, exit","   Yes, I trust this folder",""," Enter to confirm . Esc to cancel"]}}}\n' "$FM_FAKE_ORCA_WT"
        ;;
      *)
        printf '%s\n' '{"ok":true,"result":{"terminal":{"tail":["shell starting","$ "]}}}'
        ;;
    esac
    ;;
  *) printf '%s\n' '{"ok":true,"result":{}}' ;;
esac
SH
  chmod +x "$fakebin/orca"
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
  : > "$case_dir/orca.log"
  : > "$case_dir/claude.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_orca_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_ORCA_WT="$wt" TMUX='' \
    FM_FAKE_ORCA_LOG="$case_dir/orca.log" \
    FM_FAKE_CLAUDE_STATE="$case_dir/claude.state" \
    FM_CLAUDE_TRUST_POLLS=2 FM_CLAUDE_TRUST_CLEAR_POLLS=2 \
    FM_CLAUDE_TRUST_POLL_INTERVAL=0 \
    PATH="$fakebin:$NODE_BIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --backend orca --harness claude \
      --mode no-mistakes --yolo off --accept-claude-trust "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  local trust_args=()
  shift 6
  [ "${FM_TEST_CLAUDE_TRUST_AUTHORITY:-accept}" != accept ] \
    || trust_args+=(--accept-claude-trust)
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_KEY_LOG="$case_dir/keys.log" \
    FM_FAKE_CLAUDE_STATE="$case_dir/claude.state" \
    FM_FAKE_CLAUDE_MODE="${FM_FAKE_CLAUDE_MODE:-trusted}" \
    FM_CLAUDE_TRUST_POLLS="${FM_TEST_CLAUDE_TRUST_POLLS:-10}" \
    FM_CLAUDE_TRUST_CLEAR_POLLS="${FM_TEST_CLAUDE_TRUST_CLEAR_POLLS:-10}" \
    FM_CLAUDE_TRUST_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness claude --mode no-mistakes --yolo off \
      "${trust_args[@]+"${trust_args[@]}"}" "$@" 2>&1
}

test_claude_trust_dialog_requires_explicit_project_authority() {
  local id rec out rc expected bare_keys
  id="claude-no-trust-authority-z0-$$"
  rec=$(make_spawn_case no-trust-authority "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=dialog FM_TEST_CLAUDE_TRUST_AUTHORITY=absent run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an unauthorized trust dialog should leave the worker alive as a blocker"
  expected="blocked: backend=tmux task=$id requires explicit project-scoped --accept-claude-trust authority before Firstmate may accept Claude's persistent workspace-trust dialog; worker left alive on firstmate:fm-$id"
  assert_contains "$out" "$expected" \
    "the missing trust authority did not produce its project-scoped blocker"
  assert_grep "$expected" "$HOME_DIR/state/$id.status" \
    "the missing trust authority did not leave a supervisor-visible blocker"
  assert_no_grep 'claude_trust=' "$HOME_DIR/state/$id.meta" \
    "an unauthorized spawn persisted a Claude trust grant"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = Enter ] \
    || fail "an unauthorized spawn delivered trust-navigation keys: $bare_keys"
  [ "$(cat "$CASE_DIR/claude.state")" = trust-no ] \
    || fail "the unauthorized trust dialog was not left untouched"
  pass "fm-spawn: Claude trust acceptance requires explicit project-scoped authority"
}

test_claude_trust_authority_is_refused_for_other_harnesses() {
  local id rec out rc
  id="claude-trust-wrong-harness-z00-$$"
  rec=$(make_spawn_case wrong-harness "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness codex --mode no-mistakes --yolo off \
      --accept-claude-trust 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a Claude trust grant must be refused for another harness"
  assert_contains "$out" "--accept-claude-trust applies only to a Claude harness" \
    "the cross-harness trust grant refusal was not actionable"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the cross-harness trust grant refusal happened after task publication"
  pass "fm-spawn: Claude trust authority cannot broaden to another harness"
}

test_claude_focused_trust_choice_still_requires_authority() {
  local id rec out rc bare_keys
  id="claude-focused-no-authority-z000-$$"
  rec=$(make_spawn_case focused-no-authority "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=focused-dialog FM_TEST_CLAUDE_TRUST_AUTHORITY=absent run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a focused but unauthorized trust choice should remain blocked"
  assert_contains "$out" "requires explicit project-scoped --accept-claude-trust authority" \
    "the focused trust choice bypassed the project-scoped authority blocker"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = Enter ] \
    || fail "an unauthorized focused trust choice received a confirming Enter: $bare_keys"
  [ "$(cat "$CASE_DIR/claude.state")" = trust-yes ] \
    || fail "the unauthorized focused trust choice was not left untouched"
  pass "fm-spawn: a pre-focused Claude trust choice cannot bypass authority"
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
  assert_grep 'claude_trust=accept' "$HOME_DIR/state/$id.meta" \
    "the project-scoped Claude trust grant was not persisted for task relaunches"
  pass "fm-spawn: claude's trust dialog is navigated to \"Yes\" before Enter, never a blind Enter"
}

test_claude_focused_trust_dialog_accepts_without_navigation() {
  local id rec out rc bare_keys
  id="claude-focused-authorized-z5a-$$"
  rec=$(make_spawn_case focused-authorized "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=focused-dialog run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an authorized focused trust choice should be accepted"
  assert_contains "$out" "spawned $id harness=claude" \
    "the focused trust choice did not complete the spawn"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = "$(printf 'Enter\nEnter')" ] \
    || fail "the focused trust choice should receive only launch Enter then accept Enter - got: $bare_keys"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] \
    || fail "the focused trust choice did not resume processing the launch brief"
  pass "fm-spawn: an authorized focused trust choice accepts without unnecessary navigation"
}

test_claude_slow_accept_repaint_never_receives_a_second_enter() {
  local id rec out rc bare_keys
  id="claude-slow-accept-repaint-z5b-$$"
  rec=$(make_spawn_case slow-accept-repaint "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=slow-accept-repaint run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a stale post-accept frame should remain in verification-only polling"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = "$(printf 'Enter\nDown\nEnter')" ] \
    || fail "a stale post-accept frame received another Enter: $bare_keys"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] \
    || fail "the slow trust-dialog repaint did not settle into brief processing"
  pass "fm-spawn: post-accept polling never sends another key"
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

test_claude_dialog_disappearance_before_acceptance_is_unconfirmed() {
  local id rec out rc bare_keys
  id="claude-disappears-before-accept-z6a-$$"
  rec=$(make_spawn_case disappears-before-accept "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=disappears-after-down run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a dialog that disappears before acceptance must fail the spawn"
  assert_contains "$out" "claude's workspace-trust dialog disappeared before acceptance was attempted" \
    "dialog disappearance before acceptance was misreported as accepted trust"
  assert_grep "failed: claude's workspace-trust dialog disappeared before acceptance was attempted" \
    "$HOME_DIR/state/$id.status" \
    "dialog disappearance before acceptance lacked its distinct failure record"
  assert_not_contains "$out" "claude accepted the workspace-trust dialog" \
    "dialog disappearance before acceptance was falsely recorded as accepted trust"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = "$(printf 'Enter\nDown')" ] \
    || fail "the disappearing dialog received an acceptance Enter: $bare_keys"
  pass "fm-spawn: dialog disappearance before acceptance remains unconfirmed"
}

test_claude_busy_after_down_before_acceptance_is_unconfirmed() {
  local id rec out rc bare_keys
  id="claude-busy-before-accept-z6b-$$"
  rec=$(make_spawn_case busy-before-accept "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=busy-after-down run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a busy footer before acceptance must not satisfy the trust postcondition"
  assert_contains "$out" "claude's workspace-trust dialog disappeared before acceptance was attempted" \
    "a pre-accept busy footer bypassed the distinct disappearance failure"
  assert_not_contains "$out" "spawned $id harness=claude" \
    "a pre-accept busy footer falsely completed the spawn"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = "$(printf 'Enter\nDown')" ] \
    || fail "the pre-accept busy case received an acceptance Enter: $bare_keys"
  pass "fm-spawn: a busy footer cannot replace an acceptance attempt"
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

test_claude_already_trusted_idle_spawn_has_no_processing_requirement() {
  local id rec out rc
  id="claude-trusted-idle-z7-$$"
  rec=$(make_spawn_case trusted-idle "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=trusted-idle run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an already-trusted idle Claude launch should retain the existing spawn contract"
  assert_contains "$out" "spawned $id harness=claude" \
    "an already-trusted idle spawn was incorrectly subjected to the post-accept processing requirement"
  pass "fm-spawn: an already-trusted idle Claude launch keeps the common-path contract"
}

test_claude_dialog_observation_replaces_a_failed_baseline() {
  local id rec out rc
  id="claude-baseline-failed-z8-$$"
  rec=$(make_spawn_case baseline-failed "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=dialog-baseline-failed run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an observed dialog followed by active processing should survive an earlier unreadable pane"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] \
    || fail "the observed dialog did not transition to brief processing"
  pass "fm-spawn: dialog-present to dialog-absent processing is sufficient transition proof"
}

test_claude_stale_dialog_scrollback_never_receives_keys() {
  local id rec out rc bare_keys
  id="claude-stale-dialog-z9-$$"
  rec=$(make_spawn_case stale-dialog "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=stale-dialog run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "stale dialog scrollback should not affect an active already-trusted launch"
  bare_keys=$(awk 'NF == 4 {print $4}' "$CASE_DIR/keys.log")
  [ "$bare_keys" = Enter ] \
    || fail "stale dialog scrollback caused dialog-accept keys to reach the active launch: $bare_keys"
  pass "fm-spawn: stale dialog scrollback cannot trigger acceptance keys"
}

test_claude_unreadable_settle_window_fails_with_uncertainty() {
  local id rec out rc
  id="claude-unreadable-z10-$$"
  rec=$(make_spawn_case unreadable "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=unreadable run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable launch settle window must fail closed"
  assert_contains "$out" "claude's launch state could not be confirmed within the settle window - a trust dialog may still be pending" \
    "the unreadable settle window lacked its distinct uncertainty diagnostic"
  assert_grep "failed: claude's launch state could not be confirmed within the settle window - a trust dialog may still be pending" \
    "$HOME_DIR/state/$id.status" \
    "the unreadable settle window did not leave a supervisor-visible uncertainty failure"
  pass "fm-spawn: an unreadable settle window fails loudly instead of assuming trust"
}

test_claude_blank_capture_remains_inconclusive() {
  local id rec out rc
  id="claude-blank-delayed-z11-$$"
  rec=$(make_spawn_case blank-delayed "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=blank-delayed-dialog FM_TEST_CLAUDE_TRUST_POLLS=3 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a transient blank capture must remain inside the dialog detection window"
  assert_contains "$(cat "$CASE_DIR/keys.log")" "Down" \
    "a transient blank capture was mistaken for an already-trusted launch"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] \
    || fail "the dialog following a blank capture did not reach brief processing"
  pass "fm-spawn: a blank capture remains inconclusive until the delayed dialog appears"
}

test_claude_final_detection_poll_gets_a_full_clear_budget() {
  local id rec out rc
  id="claude-final-detection-z12-$$"
  rec=$(make_spawn_case final-detection "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_CLAUDE_MODE=last-poll-dialog FM_TEST_CLAUDE_TRUST_POLLS=2 \
    FM_TEST_CLAUDE_TRUST_CLEAR_POLLS=2 run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "a dialog first seen on the final detection poll must still clear and verify"
  [ "$(cat "$CASE_DIR/claude.state")" = processing ] \
    || fail "the final-poll dialog did not receive its independent clear and verification budget"
  pass "fm-spawn: final-poll detection retains a full dialog-clearance budget"
}

test_claude_orca_capability_gap_stays_alive_and_loud() {
  local id rec out rc expected count
  id="claude-orca-gap-z13-$$"
  rec=$(make_spawn_case orca-gap "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(run_orca_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  expect_code 0 "$rc" "an Orca trust dialog should leave the worker alive for manual clearance"
  expected="blocked: backend=orca task=$id requires a human keystroke to clear Claude's workspace-trust dialog; select \"Yes, I trust this folder\" with Down, then press Enter; worker left alive on term-1"
  count=$(printf '%s\n' "$out" | grep -Fxc "$expected" || true)
  [ "$count" = 1 ] || fail "the Orca capability gap should emit exactly one actionable diagnostic, got $count"
  assert_grep "$expected" "$HOME_DIR/state/$id.status" \
    "the Orca capability gap did not leave a supervisor-visible blocker"
  assert_not_contains "$(cat "$CASE_DIR/orca.log")" "Down" \
    "the spawn attempted a key Orca is guaranteed to reject"
  assert_not_contains "$out" "unsupported Orca key" \
    "the capability gap was detected only after Orca rejected the key"
  [ "$(cat "$CASE_DIR/claude.state")" = trust-no ] \
    || fail "the Orca worker did not remain alive on the workspace-trust dialog"
  assert_contains "$out" "spawned $id harness=claude" \
    "the non-fatal Orca capability gap incorrectly failed the spawn"
  pass "fm-spawn: Orca leaves Claude alive and loudly requests manual trust clearance"
}

test_claude_trust_dialog_requires_explicit_project_authority
test_claude_trust_authority_is_refused_for_other_harnesses
test_claude_focused_trust_choice_still_requires_authority
test_claude_already_trusted_spawn_never_touches_the_dialog
test_claude_trust_dialog_is_navigated_never_a_blind_enter
test_claude_focused_trust_dialog_accepts_without_navigation
test_claude_slow_accept_repaint_never_receives_a_second_enter
test_claude_stuck_dialog_fails_loudly
test_claude_accept_without_processing_fails_loudly
test_claude_dialog_disappearance_before_acceptance_is_unconfirmed
test_claude_busy_after_down_before_acceptance_is_unconfirmed
test_claude_delayed_trust_dialog_is_not_missed
test_claude_stale_busy_scrollback_cannot_confirm_processing
test_claude_already_trusted_idle_spawn_has_no_processing_requirement
test_claude_dialog_observation_replaces_a_failed_baseline
test_claude_stale_dialog_scrollback_never_receives_keys
test_claude_unreadable_settle_window_fails_with_uncertainty
test_claude_blank_capture_remains_inconclusive
test_claude_final_detection_poll_gets_a_full_clear_budget
test_claude_orca_capability_gap_stays_alive_and_loud
