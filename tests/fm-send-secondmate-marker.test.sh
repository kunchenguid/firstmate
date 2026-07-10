#!/usr/bin/env bash
# fm-send from-firstmate marker for secondmate targets.
#
# A secondmate is itself a firstmate, so a request relayed to it lands in its own
# chat - which the main firstmate never reads (the only channel back is the terse
# status file). fm-send therefore prepends a from-firstmate marker
# (bin/fm-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=secondmate, so the secondmate can recognize
# the request and route its reply via the status path. These tests pin that
# behavior hermetically (stubbed tmux, no real agent):
#   1. A send to a kind=secondmate task selector prepends the marker to the text.
#   2. A send to a crewmate (kind=ship) target sends the bare text, no marker.
#   3. An explicit session:window target (no meta) is never marked.
#   4. The --key path never carries the marker.
#   5. The marker is exactly the label "[fm-from-firstmate]" + ASCII 0x1f, and the
#      fm_message_from_firstmate detector keys on that untypable sequence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# FM_SEND_LOG and (b) lets fm-send's submit path reach a clean "empty" verdict.
# display-message yields a numeric cursor_y; capture-pane returns an empty
# bordered composer so fm_tmux_composer_state reads "empty" (submit landed) on the
# first Enter. Only the literal (-l) text is logged; Enter retries and --key sends
# are not, so the log holds exactly what was typed into the composer.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). FM_ROOT_OVERRIDE points at the same non-repo home so
# fm-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# FM_SEND_SETTLE=0 keeps the run fast. Truncates the log first; returns fm-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_secondmate_target_is_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to a secondmate target should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"audit\ the\ build) : ;;
    *) fail "secondmate send: literal text should be marker+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  pass "fm-send: a kind=secondmate target gets the from-firstmate marker prepended"
}

test_exact_secondmate_task_id_is_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/sm-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-exact)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact secondmate task id should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"audit\ the\ build) : ;;
    *) fail "exact secondmate send: literal text should be marker+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  pass "fm-send: an exact kind=secondmate task id gets the from-firstmate marker prepended"
}

test_crewmate_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home crew)
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "fm-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a crewmate target should succeed"
  got=$(cat "$log")
  [ "$got" = "fix the test" ] \
    || fail "crewmate send: expected bare text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: a kind=ship (crewmate) target is sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # No meta lookup happens for an explicit session:window target, so even with a
  # same-named secondmate meta present it must stay unmarked (escape hatch).
  fm_write_secondmate_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: an explicit session:window target is never marked"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to a secondmate should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  pass "fm-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_unit_separator() {
  local us hex
  us=$(printf '\037')
  [ "$FM_FROMFIRST_MARK" = "[fm-from-firstmate]$us" ] \
    || fail "marker is not the expected label + 0x1f sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -c)"
  # The last byte must be ASCII unit separator 0x1f, the untypable guarantee.
  hex=$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *1f) : ;;
    *) fail "marker does not end in a 0x1f byte; bytes were: $hex" ;;
  esac
  # The detector keys on that exact untypable sequence.
  fm_message_from_firstmate "${FM_FROMFIRST_MARK}do the work" \
    || fail "detector should recognize a marked message"
  fm_message_from_firstmate "do the work" \
    && fail "detector must reject an unmarked message"
  # The bare label without the separator (the typable part) is NOT a match.
  fm_message_from_firstmate "[fm-from-firstmate]do the work" \
    && fail "detector must reject the label without the 0x1f separator"
  pass "fm-send: the marker is exactly '[fm-from-firstmate]' + ASCII 0x1f, detector keys on it"
}

test_secondmate_target_is_marked
test_exact_secondmate_task_id_is_marked
test_crewmate_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_unit_separator
