#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup,
# session-lock holder detection, and the directory-trust launch gate.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$grok_home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  GROK_HOME="$grok_home" \
    FM_GROK_POLL_INTERVAL="${FM_GROK_POLL_INTERVAL:-0}" \
    FM_GROK_READY_POLLS="${FM_GROK_READY_POLLS:-12}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" grok --mode no-mistakes --yolo off
}

# Pane stub for the directory-trust gate. The shared spawn fake only paints an
# already-trusted footer. This one paints the 1.0.70 dialog, partial and decoy
# text, and the two ready signals (empty composer, idle footer) apart.
install_grok_trust_tmux() {
  local fakebin=$1 case_dir=$2
  : > "$case_dir/grok.state"
  : > "$case_dir/y.log"
  : > "$case_dir/launch.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state_file=${FM_FAKE_GROK_STATE:-}
y_log=${FM_FAKE_GROK_Y_LOG:-/dev/null}
launch_log=${FM_FAKE_LAUNCH_LOG:-/dev/null}
blanked=${FM_FAKE_GROK_BLANKED:-/tmp/fm-grok-trust-blanked-unset}
state=
[ -z "$state_file" ] || state=$(cat "$state_file" 2>/dev/null || true)
trust_screen() {
  printf '%s\n' \
    'Do you trust the contents of this directory?' \
    'Grok Build may run or modify contents in this directory,' \
    'posing security risks.' \
    'Enter or y to trust' \
    'y  Yes, proceed' \
    'n  No, quit'
  if [ "${FM_FAKE_GROK_TRUST_HAS_READY_FOOTER:-no}" = yes ]; then
    printf 'Shift+Tab:mode\n'
  fi
}
wrapped_screen() {
  printf '%s\n' \
    'Do you trust the contents of this directory?' \
    'Grok Build may run or modify contents in this directory,' \
    'posing security risks.' \
    'Enter or y' \
    'to trust' \
    'y  Yes, proceed' \
    'n  No, quit'
}
ready_screen() {
  case "${FM_FAKE_GROK_READY_SCREEN:-composer}" in
    footer) printf 'Shift+Tab:mode\n' ;;
    *) printf '  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯\n' ;;
  esac
}
fake_screen() {
  case "$state" in
    ready) ready_screen ;;
    trust) trust_screen ;;
    trust-wrapped) wrapped_screen ;;
    trust-partial)
      printf '%s\n' 'Do you trust the contents of this directory?' 'Yes, proceed'
      ;;
    trust-decoy)
      printf '%s\n' 'Do you trust the contents of this directory?' 'Yes, proceed' 'No, quit'
      ;;
    trust-old)
      printf '%s\n' 'Trust this folder?' 'Yes, proceed' 'No, cancel'
      ;;
    banner-only|banner-first) printf 'Shift+Tab:mode\nstarting\n' ;;
    busy) printf 'Ctrl+c:cancel\n' ;;
    blank-frame) ;;
    *) printf 'shell starting\n$ \n' ;;
  esac
}
note_answer() {
  printf 'y\n' >> "$y_log"
  case "$state" in
    trust|trust-wrapped)
      answers=$(wc -l < "$y_log" | tr -d ' ')
      case "${FM_FAKE_GROK_TRUST_CLEARS:-yes}" in
        yes) printf 'ready\n' > "$state_file" ;;
        after-second) [ "$answers" -lt 2 ] || printf 'ready\n' > "$state_file" ;;
      esac
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "${state_file}.window" ] || cat "${state_file}.window"
    exit 0 ;;
  new-window)
    name= previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "${state_file}.window"
    exit 0 ;;
  kill-window) : > "${state_file}.window"; exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
  send-keys)
    prev= literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'")
          staged=${literal#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || literal=$(cat "$staged")
          ;;
      esac
      case "$literal" in
        y) note_answer ;;
        *'grok --always-approve'*)
          printf '%s\n' "$literal" >> "$launch_log"
          printf 'launched\n' > "$state_file"
          ;;
      esac
      exit 0
    fi
    key=${@: -1}
    case "$key" in
      y) note_answer ;;
      Enter)
        case "$state" in
          launched)
            case "${FM_FAKE_GROK_TRUST:-remembered}" in
              fresh) printf 'trust\n' > "$state_file" ;;
              wrapped) printf 'trust-wrapped\n' > "$state_file" ;;
              partial) printf 'trust-partial\n' > "$state_file" ;;
              decoy) printf 'trust-decoy\n' > "$state_file" ;;
              old) printf 'trust-old\n' > "$state_file" ;;
              late) printf 'booting\n' > "$state_file" ;;
              blink) printf 'banner-first\n' > "$state_file" ;;
              shell) printf 'shell\n' > "$state_file" ;;
              busy) printf 'busy\n' > "$state_file" ;;
              *) printf 'ready\n' > "$state_file" ;;
            esac
            ;;
        esac
        ;;
    esac
    exit 0 ;;
  capture-pane)
    start= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
      esac
      case "$arg" in -S) prev=$arg ;; *) prev= ;; esac
    done
    if [ "$start" = -0 ] && [ "${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" = yes ]; then
      echo "can't find pane" >&2
      exit 1
    fi
    if [ "$start" = -0 ]; then
      case "$state" in
        booting) printf 'banner-only\n' > "$state_file" ;;
        banner-first) printf 'blank-frame\n' > "$state_file" ;;
        blank-frame) printf 'banner-only\n' > "$state_file" ;;
        banner-only) printf 'trust\n' > "$state_file" ;;
      esac
    fi
    if [ "$start" = -0 ] && [ "${FM_FAKE_GROK_BLANK_AFTER_TRUST:-no}" = yes ] \
       && [ -s "$y_log" ] && [ ! -f "$blanked" ]; then
      : > "$blanked"
      exit 0
    fi
    if [ "$start" = -120 ] && [ "${FM_FAKE_GROK_HISTORY_KEEPS_DIALOG:-no}" = yes ] \
       && [ -s "$y_log" ]; then
      trust_screen
    fi
    fake_screen
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

read_grok_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR GROK_HOME_DIR TASK_ID <<EOF
$1
EOF
}

run_grok_trust_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6 case_dir=$7
  FM_FAKE_GROK_STATE="$case_dir/grok.state" \
    FM_FAKE_GROK_Y_LOG="$case_dir/y.log" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_GROK_BLANKED="$case_dir/grok.blanked" \
    run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id"
}

y_count() {
  wc -l < "$1" | tr -d ' '
}

prepare_grok_trust() { # <name>
  local rec
  rec=$(make_spawn_case "$1")
  read_grok_case "$rec"
  install_grok_trust_tmux "$FAKEBIN_DIR" "$CASE_DIR"
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_grok_fresh_directory_trust_is_answered_once() {
  local out rc viewport
  prepare_grok_trust trust-fresh
  rc=0
  out=$(FM_FAKE_GROK_TRUST=fresh run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "a fresh Grok trust dialog should advance into a verified spawn"
  assert_contains "$out" "spawned $TASK_ID harness=grok" \
    "Grok spawn did not continue after the trust dialog cleared"
  [ "$(y_count "$CASE_DIR/y.log")" = 1 ] \
    || fail "a Grok trust dialog that cleared on its first answer was answered again"
  viewport=$(FM_FAKE_GROK_STATE="$CASE_DIR/grok.state" \
    "$FAKEBIN_DIR/tmux" capture-pane -p -S -0)
  assert_contains "$viewport" '❯' "Grok did not leave a visible ready composer at spawn success"
  case "$viewport" in
    *'Do you trust the contents of this directory?'*|*'Yes, proceed'*|*'No, quit'*)
      fail "Grok reported spawn success while the directory trust dialog was still visible"
      ;;
  esac
  pass "fm-spawn: a fresh Grok directory answers the exact trust dialog once and verifies it cleared"
}

test_grok_swallowed_trust_y_is_retried_until_the_dialog_clears() {
  local out rc
  prepare_grok_trust trust-swallow
  rc=0
  out=$(FM_FAKE_GROK_TRUST=fresh FM_FAKE_GROK_TRUST_CLEARS=after-second run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "a swallowed first trust y should be retried into a verified spawn"
  assert_contains "$out" "spawned $TASK_ID harness=grok" \
    "Grok spawn did not recover from a swallowed trust keypress"
  [ "$(y_count "$CASE_DIR/y.log")" = 2 ] \
    || fail "Grok trust dialog was not re-answered exactly until it cleared"
  pass "fm-spawn: a swallowed Grok trust y is re-sent until the dialog clears"
}

test_grok_wrapped_trust_hint_is_answered() {
  local out rc
  prepare_grok_trust trust-wrapped
  rc=0
  out=$(FM_FAKE_GROK_TRUST=wrapped run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "a trust dialog whose hint wrapped should be answered"
  [ "$(y_count "$CASE_DIR/y.log")" = 1 ] \
    || fail "Grok did not answer a wrapped-hint trust dialog exactly once"
  pass "fm-spawn: a Grok trust dialog with its hint wrapped across rows is answered normally"
}

test_grok_already_trusted_composer_sends_no_y() {
  local out rc
  prepare_grok_trust trusted-composer
  rc=0
  out=$(FM_FAKE_GROK_TRUST=remembered FM_FAKE_GROK_READY_SCREEN=composer run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "an already trusted Grok directory should launch with no dialog"
  assert_contains "$out" "spawned $TASK_ID harness=grok" \
    "an already trusted Grok directory did not report success"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "an already trusted Grok directory was sent y"
  pass "fm-spawn: an already trusted Grok directory launches from an empty composer and sends no y"
}

test_grok_already_trusted_footer_sends_no_y() {
  local out rc
  prepare_grok_trust trusted-footer
  rc=0
  out=$(FM_FAKE_GROK_TRUST=remembered FM_FAKE_GROK_READY_SCREEN=footer run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "an already trusted Grok directory should launch from the idle footer alone"
  assert_contains "$out" "spawned $TASK_ID harness=grok" \
    "the idle footer was not enough to accept an already trusted Grok directory"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "the idle-footer ready signal still sent y"
  pass "fm-spawn: an already trusted Grok directory launches from the idle footer and sends no y"
}

test_grok_late_dialog_does_not_pass_on_the_banner() {
  local out rc
  prepare_grok_trust trust-late
  rc=0
  out=$(FM_FAKE_GROK_TRUST=late run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "a ready-looking frame before the dialog should wait, then trust"
  [ "$(y_count "$CASE_DIR/y.log")" = 1 ] \
    || fail "the trust dialog painted after the banner was not answered exactly once"
  pass "fm-spawn: a ready-looking Grok frame captured before the trust dialog paints does not finish the spawn"
}

test_grok_blank_frame_restarts_the_ready_count() {
  local out rc
  prepare_grok_trust trust-blink
  rc=0
  out=$(FM_FAKE_GROK_TRUST=blink run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "a blank frame between ready-looking captures should not finish the spawn"
  [ "$(y_count "$CASE_DIR/y.log")" = 1 ] \
    || fail "Grok did not answer the trust dialog that painted after the blank frame"
  pass "fm-spawn: a blank Grok frame between ready-looking captures restarts the two-capture count"
}

test_grok_scrollback_does_not_reanswer() {
  local out rc
  prepare_grok_trust trust-history
  rc=0
  out=$(FM_FAKE_GROK_TRUST=fresh FM_FAKE_GROK_HISTORY_KEEPS_DIALOG=yes run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "an answered trust dialog still in scrollback should not block the spawn"
  case "$out" in
    *"did not clear"*) fail "Grok reported a stuck trust dialog that had already cleared" ;;
  esac
  [ "$(y_count "$CASE_DIR/y.log")" = 1 ] \
    || fail "Grok answered the trust dialog again from its scrollback copy"
  pass "fm-spawn: an answered Grok trust dialog left in scrollback is not answered again"
}

test_grok_blank_viewport_after_the_answer_costs_only_its_poll() {
  local out rc
  prepare_grok_trust trust-blank
  rc=0
  out=$(FM_FAKE_GROK_TRUST=fresh FM_FAKE_GROK_BLANK_AFTER_TRUST=yes \
    FM_FAKE_GROK_HISTORY_KEEPS_DIALOG=yes run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  expect_code 0 "$rc" "a blank viewport frame should cost one poll, not the spawn"
  case "$out" in
    *"did not clear"*) fail "a blank viewport frame was reported as a stuck trust dialog" ;;
  esac
  [ "$(y_count "$CASE_DIR/y.log")" = 1 ] \
    || fail "Grok answered the trust dialog again after a blank viewport frame"
  pass "fm-spawn: a blank Grok viewport frame costs its poll and nothing else"
}

test_grok_partial_dialog_is_not_answered() {
  local out rc
  prepare_grok_trust trust-partial
  rc=0
  out=$(FM_GROK_READY_POLLS=4 FM_FAKE_GROK_TRUST=partial run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a partial Grok trust dialog should not pass readiness"
  assert_contains "$out" "trust dialog text stayed on screen without the complete dialog" \
    "a partial Grok trust dialog lacked its concrete failure reason"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "Grok answered a trust dialog it could not fully read"
  pass "fm-spawn: Grok refuses the ready verdict while trust dialog markers remain"
}

test_grok_incomplete_dialog_is_not_answered() {
  local out rc
  prepare_grok_trust trust-decoy
  rc=0
  out=$(FM_GROK_READY_POLLS=4 FM_FAKE_GROK_TRUST=decoy run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "an incomplete Grok trust lookalike should not pass readiness"
  assert_contains "$out" "trust dialog text stayed on screen without the complete dialog" \
    "an incomplete Grok trust lookalike did not report the unanswerable dialog text"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "Grok answered an incomplete trust lookalike with y"
  pass "fm-spawn: Grok trust detection requires every observed dialog signal"
}

test_grok_older_folder_prompt_is_not_answered() {
  local out rc
  prepare_grok_trust trust-old
  rc=0
  out=$(FM_GROK_READY_POLLS=4 FM_FAKE_GROK_TRUST=old run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the older Trust this folder prompt should not pass readiness"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "Grok answered the older Trust this folder prompt"
  pass "fm-spawn: the older Grok folder prompt is not treated as the 1.0.70 directory dialog"
}

test_grok_stuck_dialog_fails_after_y_was_sent() {
  local out rc
  prepare_grok_trust trust-stuck
  rc=0
  out=$(FM_GROK_READY_POLLS=4 FM_FAKE_GROK_TRUST=fresh FM_FAKE_GROK_TRUST_CLEARS=no \
    FM_FAKE_GROK_TRUST_HAS_READY_FOOTER=yes run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a Grok trust dialog that never clears should fail"
  assert_contains "$(FM_FAKE_GROK_STATE="$CASE_DIR/grok.state" \
    FM_FAKE_GROK_TRUST_HAS_READY_FOOTER=yes "$FAKEBIN_DIR/tmux" capture-pane -p -S -0)" \
    'Shift+Tab:mode' "the stuck dialog fixture did not retain its competing ready footer"
  assert_contains "$out" "grok trust dialog did not clear after sending y for 'Yes, proceed'" \
    "a stuck Grok trust dialog lacked its concrete failure reason"
  assert_contains "$out" "'No, quit'" \
    "a stuck Grok trust diagnostic did not name the negative option"
  [ "$(y_count "$CASE_DIR/y.log")" -gt 1 ] \
    || fail "a stuck Grok trust dialog was not re-answered while it stayed on screen"
  assert_grep 'failed: grok trust dialog did not clear' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$TASK_ID.status") \
    "a stuck Grok trust dialog did not leave a supervisor-visible failure"
  case "$out" in
    *"spawned $TASK_ID harness=grok"*) fail "a stuck Grok trust dialog was reported as a successful spawn" ;;
  esac
  pass "fm-spawn: a Grok trust dialog must visibly clear before the spawn succeeds"
}

test_grok_shell_prompt_is_not_ready() {
  local out rc
  prepare_grok_trust trust-shell
  rc=0
  out=$(FM_GROK_READY_POLLS=3 FM_FAKE_GROK_TRUST=shell run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a shell prompt should not pass Grok readiness"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "a shell prompt was answered as the trust dialog"
  assert_contains "$out" "grok did not show a verified ready signal" \
    "a shell prompt lacked the not-ready diagnostic"
  pass "fm-spawn: a shell prompt is not a ready Grok session"
}

test_grok_busy_tail_is_not_ready() {
  local out rc
  prepare_grok_trust trust-busy
  rc=0
  out=$(FM_GROK_READY_POLLS=3 FM_FAKE_GROK_TRUST=busy run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "Grok's mid-turn tail should not pass readiness"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "Grok's mid-turn tail was answered as the trust dialog"
  pass "fm-spawn: Ctrl+c:cancel is not a ready Grok session"
}

test_grok_failed_viewport_read_fails_at_once() {
  local out rc
  prepare_grok_trust viewport-fail
  rc=0
  out=$(FM_FAKE_TMUX_VISIBLE_FAILS=yes FM_FAKE_GROK_TRUST=fresh run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a Grok spawn whose viewport read fails should fail"
  assert_contains "$out" "could not read the visible viewport of backend 'tmux'" \
    "a failed Grok viewport read was reported as something other than a capture failure"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "Grok pressed y without being able to read the viewport"
  pass "fm-spawn: a failed Grok viewport read fails readiness with the backend named"
}

test_grok_refuses_a_backend_without_a_viewport_capture() {
  local out rc
  prepare_grok_trust no-viewport
  fm_fake_exit0 "$FAKEBIN_DIR" cmux
  rc=0
  out=$(FM_BACKEND=cmux run_grok_trust_spawn \
    "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$GROK_HOME_DIR" "$TASK_ID" "$CASE_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a Grok spawn on a backend without a viewport capture should refuse"
  assert_contains "$out" "backend 'cmux' has no verified viewport-bounded capture" \
    "the Grok refusal did not name the backend and the missing viewport capability"
  [ "$(y_count "$CASE_DIR/y.log")" = 0 ] \
    || fail "Grok pressed y on a backend it cannot read the viewport of"
  [ ! -s "$CASE_DIR/launch.log" ] \
    || fail "Grok was launched on a backend without a viewport capture"
  pass "fm-spawn: Grok refuses a backend that cannot read the viewport, before launching"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
test_grok_fresh_directory_trust_is_answered_once
test_grok_swallowed_trust_y_is_retried_until_the_dialog_clears
test_grok_wrapped_trust_hint_is_answered
test_grok_already_trusted_composer_sends_no_y
test_grok_already_trusted_footer_sends_no_y
test_grok_late_dialog_does_not_pass_on_the_banner
test_grok_blank_frame_restarts_the_ready_count
test_grok_scrollback_does_not_reanswer
test_grok_blank_viewport_after_the_answer_costs_only_its_poll
test_grok_partial_dialog_is_not_answered
test_grok_incomplete_dialog_is_not_answered
test_grok_older_folder_prompt_is_not_answered
test_grok_stuck_dialog_fails_after_y_was_sent
test_grok_shell_prompt_is_not_ready
test_grok_busy_tail_is_not_ready
test_grok_failed_viewport_read_fails_at_once
test_grok_refuses_a_backend_without_a_viewport_capture
