#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

install_grok_tmux_fake() { # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_GROK_STATE" 2>/dev/null || true)
render_dialog() {
  printf 'Do you trust the contents of this directory?\n%s\n                         Yes, proceed                 y\n                         No, quit                     n\n\nGrok Build  1.0.40 [stable]\n' "$FM_FAKE_PANE_PATH"
}
# The frame Grok repaints when the pane is too short to hold the dialog body:
# its header row and build footer, with the title and shortcuts clipped away.
# A rendered dialog can only end up above the visible slice because a repaint
# like this one was painted after it, so bounded history ends with it and the
# visible slice IS it - the pane geometry a real terminal produces, rather than
# a visible slice that is no tail of the history it came from.
render_clipped() {
  printf '%s\n\n\n\nGrok Build  1.0.40 [stable]\n' "$FM_FAKE_PANE_PATH"
}
render_ready() {
  printf 'Tip: Use @ to attach files.\n╭────────────────────────────────╮\n│ ❯                              │\n╰── Weekly limit left: 50%% ──────╯\nShift+Tab:mode  │  Ctrl+x:shortcuts\nGrok Build  1.0.40 [stable]\n'
}
# An interior piece of the staged launch line, the shape a previous session's
# scrollback can hold by coincidence: a run from the home-identity token in the
# staged path, which ends nowhere near the end of that line.
render_launch_fragment() {
  [ -s "${FM_FAKE_GROK_ECHO:-/dev/null}" ] || return 0
  awk '{ print substr($0, 20, 14) }' "$FM_FAKE_GROK_ECHO"
}
# The scrollback an adopted endpoint carries into the launch: a previous Grok
# session's own surface, which is not evidence about this launch.
render_prior_session() {
  case "${FM_FAKE_GROK_MODE:-ready}" in
    stale) render_ready ;;
    fragment)
      printf 'PRIOR-SESSION-TOP\n'
      render_launch_fragment
      render_ready
      ;;
  esac
}
# The shell's echo of the staged launch line, which every real backend leaves in
# the pane between the literal and the dialog this launch renders. The wrapped
# form is the geometry a real 80-column pane with a 40-character prompt produces:
# three rows, none of which holds the whole staged file name.
render_launch_echo() {
  [ -s "${FM_FAKE_GROK_ECHO:-/dev/null}" ] || return 0
  if [ "${FM_FAKE_GROK_MODE:-ready}" = wrapped ]; then
    awk '{
      row = "demo-prompt-that-is-fortyish-chars-long % " $0
      while (length(row) > 80) {
        print substr(row, 1, 80)
        row = substr(row, 81)
      }
      print row
    }' "$FM_FAKE_GROK_ECHO"
    return 0
  fi
  cat "$FM_FAKE_GROK_ECHO"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|set-window-option|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'")
          staged=${literal#". '"}
          staged=${staged%"'"}
          printf '%s\n' "$literal" > "$FM_FAKE_GROK_ECHO"
          [ ! -f "$staged" ] || literal=$(cat "$staged")
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_GROK_STATE"
          ;;
        y)
          printf 'y\n' >> "$FM_FAKE_GROK_TRUST_ANSWER_LOG"
          printf 'history\n' > "$FM_FAKE_GROK_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        if [ "$state" = launched ]; then
          case "${FM_FAKE_GROK_MODE:-ready}" in
            active) printf 'trust\n' > "$FM_FAKE_GROK_STATE" ;;
            historical) printf 'history\n' > "$FM_FAKE_GROK_STATE" ;;
            stale) printf 'stale\n' > "$FM_FAKE_GROK_STATE" ;;
            wrapped) printf 'history\n' > "$FM_FAKE_GROK_STATE" ;;
            fragment) printf 'fragment\n' > "$FM_FAKE_GROK_STATE" ;;
            *) printf 'ready\n' > "$FM_FAKE_GROK_STATE" ;;
          esac
        fi
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -S ]; then start=$arg; break; fi
      [ "$arg" = -S ] && prev=-S || prev=
    done
    # Every capture taken after the launch line was submitted is one poll of the
    # trust gate, so suites can assert how far it had to look.
    polls=0
    case "$state" in
      trust|history|ready|stale|fragment)
        polls=$(cat "${FM_FAKE_GROK_POLL_COUNT:-/dev/null}" 2>/dev/null || true)
        case "$polls" in ''|*[!0-9]*) polls=0 ;; esac
        polls=$((polls + 1))
        [ -z "${FM_FAKE_GROK_POLL_COUNT:-}" ] \
          || printf '%s\n' "$polls" > "$FM_FAKE_GROK_POLL_COUNT"
        ;;
    esac
    case "$state" in
      trust)
        if [ "$start" = -0 ]; then
          render_clipped
        else
          render_prior_session; render_launch_echo; render_dialog; render_clipped
        fi
        ;;
      history) render_prior_session; render_launch_echo; render_dialog; render_ready ;;
      ready) render_prior_session; render_launch_echo; render_ready ;;
      launched) render_prior_session; render_launch_echo ;;
      stale)
        # This launch has painted nothing yet on its first poll; the dialog it
        # renders arrives only on the poll after that.
        render_prior_session
        render_launch_echo
        [ "$polls" -lt 2 ] || render_dialog
        ;;
      fragment)
        # This launch's TUI has painted over the row carrying the echo, so the
        # capture keeps only the adopted scrollback - including its coincidental
        # fragment of the staged path - until the dialog renders.
        render_prior_session
        [ "$polls" -lt 2 ] || render_dialog
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  install_grok_tmux_fake "$fakebin"
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$grok_home"
  : > "$case_dir/grok.state"
  : > "$case_dir/grok-trust-answer.log"
  : > "$case_dir/grok-echo.log"
  : > "$case_dir/grok-poll-count"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6 case_dir
  case_dir=${home%/home}
  GROK_HOME="$grok_home" \
    FM_FAKE_GROK_STATE="$case_dir/grok.state" \
    FM_FAKE_GROK_MODE="${FM_FAKE_GROK_MODE:-ready}" \
    FM_FAKE_GROK_TRUST_ANSWER_LOG="$case_dir/grok-trust-answer.log" \
    FM_FAKE_GROK_ECHO="$case_dir/grok-echo.log" \
    FM_FAKE_GROK_POLL_COUNT="$case_dir/grok-poll-count" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_GROK_TRUST_POLLS=3 FM_GROK_TRUST_POLL_INTERVAL=0 \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" grok --mode no-mistakes --yolo off
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

test_grok_active_trust_dialog_below_visible_slice_fails() {
  local rec case_dir home proj wt fakebin grok_home id out rc visible bounded
  rec=$(make_spawn_case trust-active)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  rc=0
  out=$(FM_FAKE_GROK_MODE=active run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "grok spawn accepted an active project-folder trust dialog"
  assert_contains "$out" "active project-folder trust dialog" \
    "grok spawn did not report the active trust gate"
  assert_contains "$out" "refusing to grant project content and hooks additional execution authority automatically" \
    "grok spawn did not preserve the project-content trust boundary"
  assert_grep ' -S -200' "$case_dir/tmux-calls.log" \
    "grok trust detection did not inspect bounded history"
  visible=$(FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_GROK_STATE="$case_dir/grok.state" FM_FAKE_PANE_PATH="$wt" \
    "$fakebin/tmux" capture-pane -p -t fake -S -0)
  bounded=$(FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_GROK_STATE="$case_dir/grok.state" FM_FAKE_PANE_PATH="$wt" \
    "$fakebin/tmux" capture-pane -p -t fake -S -200)
  assert_not_contains "$visible" "Do you trust the contents of this directory?" \
    "the below-fold fixture left the active dialog title in its visible slice"
  assert_contains "$visible" "Grok Build  1.0.40 [stable]" \
    "the below-fold fixture did not retain the active Grok frame footer"
  assert_contains "$bounded" "Do you trust the contents of this directory?" \
    "the below-fold fixture kept no complete dialog frame in bounded history"
  # A pane whose visible slice is not the tail of its own history is a pane no
  # terminal geometry produces, and a gate proven only against one is proven
  # against nothing.
  [ "$(printf '%s\n' "$bounded" | tail -n "$(printf '%s\n' "$visible" | wc -l)")" \
    = "$visible" ] \
    || fail "the below-fold fixture modelled a pane whose visible slice is not the tail of its bounded history"
  [ ! -s "$case_dir/grok-trust-answer.log" ] \
    || fail "grok spawn answered the trust dialog instead of refusing it"
  assert_not_contains "$out" "spawned $id" \
    "grok trust refusal still reported a successful worker"
  assert_contains "$out" "the unconfirmed endpoint will be closed" \
    "grok trust refusal did not state what happens to the endpoint it refused"
  # The refusal runs after the task record is published, so nothing else owns
  # this endpoint: an unclosed pane leaves Grok parked on the dialog outside
  # task control, and the message above would be a promise the spawn never kept.
  assert_grep "kill-window -t =firstmate:=fm-$id" "$case_dir/tmux-calls.log" \
    "grok trust refusal left the unconfirmed endpoint running"
  pass "fm-spawn: Grok detects an active trust frame above the visible slice, refuses its grant, and closes the endpoint"
}

test_grok_trust_dialog_after_adopted_scrollback_fails() {
  local rec case_dir home proj wt fakebin grok_home id out rc baseline polls
  rec=$(make_spawn_case trust-stale)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  rc=0
  out=$(FM_FAKE_GROK_MODE=stale run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || rc=$?
  printf 'launched\n' > "$case_dir/baseline.state"
  baseline=$(FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" FM_FAKE_GROK_MODE=stale \
    FM_FAKE_GROK_ECHO="$case_dir/grok-echo.log" FM_FAKE_GROK_STATE="$case_dir/baseline.state" \
    FM_FAKE_PANE_PATH="$wt" "$fakebin/tmux" capture-pane -p -t fake -S -200)
  assert_contains "$baseline" "Weekly limit left:" \
    "the adopted-scrollback fixture carried no prior session surface into the launch"
  assert_not_contains "$baseline" "Do you trust the contents of this directory?" \
    "the adopted-scrollback fixture already showed this launch's dialog before it rendered"
  [ "$rc" -ne 0 ] || fail "grok spawn read an adopted session surface as proof that this launch has no trust dialog"
  assert_contains "$out" "active project-folder trust dialog" \
    "grok spawn did not report the trust gate that rendered after the adopted scrollback"
  polls=$(cat "$case_dir/grok-poll-count")
  [ "${polls:-0}" -ge 2 ] \
    || fail "grok trust detection stopped polling on the first capture, before this launch had painted anything"
  [ ! -s "$case_dir/grok-trust-answer.log" ] \
    || fail "grok spawn answered the trust dialog instead of refusing it"
  assert_not_contains "$out" "spawned $id" \
    "grok trust refusal still reported a successful worker"
  pass "fm-spawn: Grok ignores an adopted session surface and still catches the dialog this launch renders"
}

test_grok_scrollback_fragment_of_launch_line_is_not_a_boundary() {
  local rec case_dir home proj wt fakebin grok_home id out rc literal fragment polls
  rec=$(make_spawn_case trust-fragment)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  rc=0
  out=$(FM_FAKE_GROK_MODE=fragment run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || rc=$?
  literal=$(cat "$case_dir/grok-echo.log")
  fragment=$(printf '%s\n' "$literal" | awk '{ print substr($0, 20, 14) }')
  [ -n "$fragment" ] || fail "the fragment fixture derived no piece of the staged launch line"
  case "$literal" in
    *"$fragment"*) ;;
    *) fail "the fragment fixture row is not a piece of the staged launch line at all" ;;
  esac
  case "$literal" in
    *"$fragment") fail "the fragment fixture row ends the staged launch line, so it is an echo row rather than an interior piece" ;;
  esac
  [ "$rc" -ne 0 ] || fail "grok spawn read adopted scrollback as this launch's output because a prior row was a fragment of the staged launch line"
  assert_contains "$out" "active project-folder trust dialog" \
    "grok spawn did not report the trust gate that rendered after the adopted scrollback"
  polls=$(cat "$case_dir/grok-poll-count")
  [ "${polls:-0}" -ge 2 ] \
    || fail "grok trust detection accepted an interior fragment of the staged launch line as its post-launch boundary"
  [ ! -s "$case_dir/grok-trust-answer.log" ] \
    || fail "grok spawn answered the trust dialog instead of refusing it"
  assert_not_contains "$out" "spawned $id" \
    "grok trust refusal still reported a successful worker"
  pass "fm-spawn: Grok refuses to anchor its post-launch boundary on an interior fragment of the staged launch line"
}

test_grok_wrapped_launch_echo_keeps_post_launch_boundary() {
  local rec case_dir home proj wt fakebin grok_home id out rc mark rows flat polls
  rec=$(make_spawn_case trust-wrapped)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  rc=0
  out=$(FM_FAKE_GROK_MODE=wrapped run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || rc=$?
  mark=$(sed -n "s/^\. '\(.*\)'\$/\1/p" "$case_dir/grok-echo.log")
  mark=${mark##*/}
  [ -n "$mark" ] || fail "the wrapped fixture recorded no staged launch line"
  printf 'launched\n' > "$case_dir/baseline.state"
  rows=$(FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" FM_FAKE_GROK_MODE=wrapped \
    FM_FAKE_GROK_ECHO="$case_dir/grok-echo.log" FM_FAKE_GROK_STATE="$case_dir/baseline.state" \
    FM_FAKE_PANE_PATH="$wt" "$fakebin/tmux" capture-pane -p -t fake -S -200)
  printf '%s\n' "$rows" | grep -Fq "$mark" \
    && fail "the wrapped fixture kept the staged launch file name inside a single captured row"
  flat=$(printf '%s' "$rows" | tr -d '\n')
  case "$flat" in
    *"$mark"*) ;;
    *) fail "the wrapped fixture lost the staged launch file name from its rows entirely" ;;
  esac
  expect_code 0 "$rc" "a wrapped launch echo must not fail an otherwise clean grok dispatch"
  assert_contains "$out" "spawned $id harness=grok" \
    "a wrapped launch echo prevented a successful spawn"
  polls=$(cat "$case_dir/grok-poll-count")
  [ "${polls:-0}" -eq 1 ] \
    || fail "grok trust detection did not find its post-launch boundary across the wrapped launch echo; it polled ${polls:-0} times instead of once"
  pass "fm-spawn: Grok locates its post-launch boundary when the launch echo wraps across rows"
}

test_grok_historical_trust_dialog_does_not_block_dispatch() {
  local rec case_dir home proj wt fakebin grok_home id out rc
  rec=$(make_spawn_case trust-history)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  rc=0
  out=$(FM_FAKE_GROK_MODE=historical run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id") || rc=$?
  expect_code 0 "$rc" "historical Grok trust text followed by a live composer should not fail dispatch"
  assert_contains "$out" "spawned $id harness=grok" \
    "historical Grok trust text prevented a successful spawn"
  assert_not_contains "$out" "active project-folder trust dialog" \
    "historical Grok trust text was classified as active"
  [ ! -s "$case_dir/grok-trust-answer.log" ] \
    || fail "grok spawn answered historical trust text"
  assert_no_grep "kill-window" "$case_dir/tmux-calls.log" \
    "a confirmed grok dispatch closed the endpoint its worker was launched into"
  pass "fm-spawn: Grok ignores historical trust text followed by the current session surface"
}

# The gate above can only recover a displaced dialog from a pane that KEPT it,
# and the pane firstmate creates keeps nothing by default: a full-screen harness
# on tmux's alternate screen has no history, so the rows a repaint displaces are
# destroyed and the bounded read returns the viewport whatever it asks for. This
# pins the spawn's own request for that history - that it is made, that it names
# this task's own window, and that it lands before the first keystroke, since the
# option governs the harness's switch to a full-screen surface and one set after
# Grok is already painting governs nothing. What the option then does to a real
# pane is tmux's behavior rather than this fake's, and is pinned on a real server
# by tests/fm-backend-tmux-smoke.test.sh and against live Grok by
# tests/fm-grok-trust-dialog-live-e2e.test.sh.
test_grok_pane_keeps_the_rows_a_displaced_dialog_lands_in() {
  local rec case_dir home proj wt fakebin grok_home id out status retain typed
  rec=$(make_spawn_case trust-retain)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"
  retain=$(grep -n 'alternate-screen off' "$case_dir/tmux-calls.log" | head -1 | cut -d: -f1)
  [ -n "$retain" ] \
    || fail "grok spawn never asked its pane to keep the rows a displaced trust frame lands in"
  grep -qxF "set-window-option -t firstmate:fm-$id alternate-screen off" \
    "$case_dir/tmux-calls.log" \
    || fail "grok spawn asked for pane history somewhere other than this task's own window"
  typed=$(grep -n '^send-keys ' "$case_dir/tmux-calls.log" | head -1 | cut -d: -f1)
  [ -n "$typed" ] || fail "the fixture recorded no keystroke for this spawn to order the request against"
  [ "$retain" -lt "$typed" ] \
    || fail "grok spawn asked for pane history only after it had started typing into the pane, where the option can no longer govern the harness's own screen"
  pass "fm-spawn: a Grok pane is asked to keep its displaced rows before anything is typed into it"
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

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_grok_active_trust_dialog_below_visible_slice_fails
test_grok_trust_dialog_after_adopted_scrollback_fails
test_grok_scrollback_fragment_of_launch_line_is_not_a_boundary
test_grok_wrapped_launch_echo_keeps_post_launch_boundary
test_grok_historical_trust_dialog_does_not_block_dispatch
test_grok_pane_keeps_the_rows_a_displaced_dialog_lands_in
test_fm_lock_recognizes_grok_holder
