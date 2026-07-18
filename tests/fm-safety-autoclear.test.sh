#!/usr/bin/env bash
# Hermetic tests for Codex's `safety-buffering-prompt` auto-clear path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-tmux-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-safety-autoclear-tests.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "${1:-}" in
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:?}"; exit 0 ;;
  send-keys)
    if [ "${!#}" = Down ] && [ -n "${FM_FAKE_TMUX_AFTER_DOWN:-}" ]; then
      cp "$FM_FAKE_TMUX_AFTER_DOWN" "$FM_FAKE_TMUX_CAPTURE"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

write_prompt() {  # <path> [selected-option]
  local path=$1 selected=${2:-1} one='  1.' two='  2.' three='  3.'
  case "$selected" in
    1) one='> 1.' ;;
    2) two='> 2.' ;;
    3) three='> 3.' ;;
  esac
  {
    printf '%s\n' 'Additional safety checks'
    printf '%s\n' 'This request requires additional safety checks, which can take extra time.'
    printf '%s Retry with a faster model\n' "$one"
    printf '%s Keep waiting\n' "$two"
    printf '%s Learn more\n' "$three"
    printf '%s\n' 'Press enter to confirm or esc to go back'
  } > "$path"
}

run_clear() {  # <fakebin> <capture> <log> [after-down]
  local fb=$1 capture=$2 log=$3 after_down=${4:-}
  : > "$log"
  FM_SAFETY_AUTOCLEAR_DELAY=0 FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_AFTER_DOWN="$after_down" \
    FM_FAKE_TMUX_LOG="$log" PATH="$fb:$PATH" fm_clear_safety_prompt 'crew:fm-task'
}

test_active_prompt_selects_keep_waiting() {
  local dir fb capture after_down log expected
  dir="$TMP_ROOT/active"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; after_down="$dir/after-down"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  write_prompt "$after_down" 2
  run_clear "$fb" "$capture" "$log" "$after_down" || fail "active safety prompt was not cleared"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Down' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "auto-clear sent unexpected tmux commands"
  pass "active prompt sends Down, verifies Keep waiting, then Enter"
}

test_dropped_down_does_not_confirm() {
  local dir fb capture log
  dir="$TMP_ROOT/dropped"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  if run_clear "$fb" "$capture" "$log"; then
    fail "a dropped Down still reported a clear"
  fi
  grep -q 'send-keys -t crew:fm-task Down' "$log" || fail "no Down was attempted"
  ! grep -q 'send-keys -t crew:fm-task Enter' "$log" \
    || fail "Enter was sent while Retry with a faster model stayed selected"
  pass "a Down that does not move the selection never confirms option 1"
}

test_selected_keep_waiting_is_confirmed_without_moving() {
  local dir fb capture log expected
  dir="$TMP_ROOT/waiting"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 2
  run_clear "$fb" "$capture" "$log" || fail "selected Keep waiting was not confirmed"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-task -S -20' \
    'send-keys -t crew:fm-task Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "selected Keep waiting was moved before confirmation"
  pass "a retry after Down confirms Keep waiting without selecting Learn more"
}

test_non_menu_content_does_not_trigger() {
  local dir fb capture log
  dir="$TMP_ROOT/not-menu"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  printf '%s\n' \
    'The output mentions Additional safety checks.' \
    'The correct choice is Keep waiting.' \
    'It also quotes Press enter to confirm.' > "$capture"
  if run_clear "$fb" "$capture" "$log"; then
    fail "prose mentioning the dialog triggered auto-clear"
  fi
  ! grep -q '^send-keys ' "$log" || fail "non-menu content received keypresses"
  pass "dialog words outside the complete menu do not trigger"
}

test_disabled_does_not_capture_or_send() {
  local dir fb capture log
  dir="$TMP_ROOT/disabled"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"
  write_prompt "$capture" 1
  : > "$log"
  if FM_SAFETY_AUTOCLEAR=0 FM_SAFETY_AUTOCLEAR_DELAY=0 \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_LOG="$log" \
    PATH="$fb:$PATH" fm_clear_safety_prompt 'crew:fm-task'; then
    fail "disabled auto-clear reported that it acted"
  fi
  [ ! -s "$log" ] || fail "disabled auto-clear touched tmux"
  pass "FM_SAFETY_AUTOCLEAR=0 disables capture and keypresses"
}

run_watch() {  # <fakebin> <capture> <log> <state> <out> [after-down]
  FM_STATE_OVERRIDE="$4" FM_WATCH_KEEPALIVE=0 FM_CHECK_INTERVAL=9999999 \
    FM_HEARTBEAT=0 FM_SAFETY_AUTOCLEAR_DELAY=0 FM_FAKE_TMUX_CAPTURE="$2" \
    FM_FAKE_TMUX_AFTER_DOWN="${6:-}" \
    FM_FAKE_TMUX_LOG="$3" PATH="$1:$PATH" "$WATCH" > "$5"
}

test_watcher_clears_only_recorded_window() {
  local dir fb capture after_down log state out expected
  dir="$TMP_ROOT/watcher"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; after_down="$dir/after-down"
  log="$dir/tmux.log"; state="$dir/state"; out="$dir/out"
  mkdir -p "$state"
  write_prompt "$capture" 1
  write_prompt "$after_down" 2
  printf '%s\n' 'window=crew:fm-recorded' 'kind=ship' 'harness=codex' > "$state/task.meta"
  : > "$log"
  run_watch "$fb" "$capture" "$log" "$state" "$out" "$after_down" \
    || fail "watcher exited non-zero"
  grep -Fx 'heartbeat' "$out" >/dev/null || fail "watcher did not complete its poll"
  expected=$(printf '%s\n' \
    'capture-pane -p -t crew:fm-recorded -S -20' \
    'send-keys -t crew:fm-recorded Down' \
    'capture-pane -p -t crew:fm-recorded -S -20' \
    'send-keys -t crew:fm-recorded Enter')
  [ "$(cat "$log")" = "$expected" ] || fail "watcher touched a pane outside recorded metadata"
  [ "$(cat "$state/.count-safety-crew_fm-recorded" 2>/dev/null)" = 1 ] \
    || fail "watcher did not record the consecutive-clear count"
  pass "watcher clears the recorded codex crewmate before stale classification"
}

test_watcher_skips_non_codex_harness() {
  local dir fb capture log state out
  dir="$TMP_ROOT/non-codex"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"; state="$dir/state"; out="$dir/out"
  mkdir -p "$state"
  write_prompt "$capture" 1
  printf '%s\n' 'window=crew:fm-recorded' 'kind=ship' 'harness=claude' > "$state/task.meta"
  : > "$log"
  run_watch "$fb" "$capture" "$log" "$state" "$out" || fail "watcher exited non-zero"
  ! grep -q '^send-keys ' "$log" || fail "a non-codex pane received keypresses"
  pass "watcher never sends keys to a pane whose recorded harness is not codex"
}

test_watcher_counts_unverified_attempt() {
  local dir fb capture log state out
  dir="$TMP_ROOT/unverified"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"; state="$dir/state"; out="$dir/out"
  mkdir -p "$state"
  write_prompt "$capture" 1
  printf '%s\n' 'window=crew:fm-recorded' 'kind=ship' 'harness=codex' > "$state/task.meta"
  echo 2 > "$state/.count-safety-crew_fm-recorded"
  : > "$log"
  run_watch "$fb" "$capture" "$log" "$state" "$out" || fail "watcher exited non-zero"
  grep -q 'send-keys -t crew:fm-recorded Down' "$log" || fail "no clear was attempted"
  ! grep -q 'send-keys -t crew:fm-recorded Enter' "$log" \
    || fail "an unverified attempt still confirmed the menu"
  [ "$(cat "$state/.count-safety-crew_fm-recorded" 2>/dev/null)" = 3 ] \
    || fail "an unverified attempt did not advance the consecutive-attempt count"
  [ -e "$state/.hash-crew_fm-recorded" ] \
    || fail "an unverified attempt was exempted from stale classification"
  pass "a pane still rendering Retry after Down advances the attempt count"
}

test_watcher_caps_consecutive_clears() {
  local dir fb capture log state out
  dir="$TMP_ROOT/capped"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"; state="$dir/state"; out="$dir/out"
  mkdir -p "$state"
  write_prompt "$capture" 1
  printf '%s\n' 'window=crew:fm-recorded' 'kind=ship' 'harness=codex' > "$state/task.meta"
  echo 5 > "$state/.count-safety-crew_fm-recorded"
  : > "$log"
  run_watch "$fb" "$capture" "$log" "$state" "$out" || fail "watcher exited non-zero"
  ! grep -q '^send-keys ' "$log" || fail "a capped pane still received keypresses"
  [ -e "$state/.hash-crew_fm-recorded" ] \
    || fail "a capped pane was exempted from stale classification"
  [ -e "$state/.count-safety-crew_fm-recorded" ] \
    || fail "the clear count reset while the menu was still showing"
  pass "capped consecutive clears fall through to stale classification"
}

test_watcher_resets_clear_count_when_menu_gone() {
  local dir fb capture log state out
  dir="$TMP_ROOT/reset"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/capture"; log="$dir/tmux.log"; state="$dir/state"; out="$dir/out"
  mkdir -p "$state"
  printf '%s\n' 'ordinary working output' > "$capture"
  printf '%s\n' 'window=crew:fm-recorded' 'kind=ship' 'harness=codex' > "$state/task.meta"
  echo 5 > "$state/.count-safety-crew_fm-recorded"
  : > "$log"
  run_watch "$fb" "$capture" "$log" "$state" "$out" || fail "watcher exited non-zero"
  [ ! -e "$state/.count-safety-crew_fm-recorded" ] \
    || fail "the clear count survived the menu disappearing"
  pass "the consecutive-clear count resets once the menu is gone"
}

test_active_prompt_selects_keep_waiting
test_dropped_down_does_not_confirm
test_selected_keep_waiting_is_confirmed_without_moving
test_non_menu_content_does_not_trigger
test_disabled_does_not_capture_or_send
test_watcher_clears_only_recorded_window
test_watcher_skips_non_codex_harness
test_watcher_counts_unverified_attempt
test_watcher_caps_consecutive_clears
test_watcher_resets_clear_count_when_menu_gone
printf 'all safety auto-clear tests passed\n'
