#!/usr/bin/env bash
# fm-send pre-submit popup-settle selection (the codex `$<skill>` fix).
#
# Some TUIs open a completion popup when the composer's first character triggers
# it: codex (and others) for a leading `/` slash command, and codex specifically
# for a leading `$<skill>` invocation (e.g. `$no-mistakes`). Submitting before the
# popup settles lets it swallow the Enter, so the line never submits. fm-send
# absorbs this by pausing `settle` seconds AFTER typing and BEFORE the (retried)
# Enter - the first sleep fm_tmux_submit_core makes. These tests pin the
# settle-SELECTION matrix hermetically (stubbed tmux + sleep, no real agent):
#
#   /...            -> 1.2  (universal; `/` only starts a command, never plain text)
#   $... to codex   -> 1.2  (scoped: codex opens a `$<skill>` popup)
#   $... to claude  -> 0.3  (NOT codex: `$` commonly starts plain text "$5", "$HOME")
#   $... explicit   -> 0.3  (session:window target has no meta -> harness unknown
#                            -> non-codex safe default)
#   plain text      -> 0.3  (fast path)
#
# The popup-settle is the FIRST sleep recorded: fm_tmux_submit_core types the text,
# then `sleep "$settle"`, then the Enter-retry loop (sleep 0.4 each) and finally
# fm-send's own post-submit FM_SEND_SETTLE pause. So tail-vs-head matters: this
# suite asserts on the HEAD sleep, distinct from fm-send-settle.test.sh which pins
# the TAIL (post-submit) pause. The retried Enter in fm_tmux_submit_core remains the
# real safety net; this settle is only the optimization that lets the popup clear so
# the first Enter lands.
#
# Every case below passes a LITERAL `$<skill>` / `$price` message in single quotes
# on purpose - the whole point is to send an unexpanded `$...` line to the agent -
# so SC2016 (which flags single-quoted `$` as a probably-forgotten expansion) is a
# false positive here and is disabled file-wide.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-popup-settle)

# Same stub shape as fm-send-settle.test.sh: a fake tmux that drives the submit
# path to a clean "empty" verdict on the first Enter, and a fake sleep that records
# every requested duration (one per line) into FM_SLEEP_LOG instead of sleeping.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
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
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# first_settle <expected> <label> <harness|--explicit> <message>: build a fresh
# home, send <message> to a target whose meta records <harness> (or to a bare
# session:window with NO meta when --explicit), and assert the FIRST recorded sleep
# (the popup-settle) equals <expected>. FM_SEND_SETTLE=0 strips the trailing
# post-submit pause so the log holds only the popup-settle plus the 0.4 Enter wait,
# keeping the head assertion crisp. FM_ROOT_OVERRIDE points at a non-repo dir so
# fm-guard's tangle check stays silent; its watcher-liveness note goes to stderr
# (discarded).
first_settle() {  # <expected> <label> <harness|--explicit> <message>
  local expected=$1 label=$2 harness=$3 msg=$4
  local dir fb log home target rc first
  dir="$TMP_ROOT/case-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"; home="$dir"
  if [ "$harness" = --explicit ]; then
    target="sess:win"
  else
    target="fm-popupcase"
    fm_write_meta "$home/state/popupcase.meta" "window=sess:win" "harness=$harness"
  fi
  : > "$log"
  env FM_SEND_SETTLE=0 PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "$target" "$msg" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  first=$(head -1 "$log")
  [ "$first" = "$expected" ] || fail "$label: expected popup-settle $expected, got '$first'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send popup-settle: $label -> ${expected}s"
}

# Codex `$<skill>` gets the long settle so its `$` popup clears (the fix).
first_settle 1.2 'codex $skill -> long settle' codex '$no-mistakes'

# Same `$` message to claude keeps the fast path: `$` is ordinary text there.
first_settle 0.3 'claude $-message -> fast path' claude '$no-mistakes'

# `$`-prefixed plain text to claude (a price) must NOT popup-settle - the regression
# the codex scoping exists to prevent.
first_settle 0.3 'claude "$5/month" -> fast path' claude '$5/month is cheap'

# An explicit session:window target has no meta, so the harness is unknown and
# treated as non-codex: the safe default keeps the fast path even for a `$` message.
first_settle 0.3 'explicit target $message -> fast path (unknown harness)' --explicit '$no-mistakes'

# The `/` slash case stays universal and unchanged: long settle regardless of
# harness (here a non-codex claude target).
first_settle 1.2 'claude /command -> long settle (slash unchanged)' claude '/no-mistakes'

# A `/` to codex is likewise still the long settle (slash path untouched).
first_settle 1.2 'codex /command -> long settle (slash unchanged)' codex '/help'

# Plain text to codex takes the fast path - the codex scope is `$`-prefixed only.
first_settle 0.3 'codex plain text -> fast path' codex 'just a normal steer'
