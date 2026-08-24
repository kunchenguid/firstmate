#!/usr/bin/env bash
# tests/fm-tmux-submit-dash-literal.test.sh - regression: a message whose text
# begins with "-" used to be consumed by tmux's own option parser.
#
# Incident 2026-08-24 (window fm-captain-brett-gex-magiclink): steers were
# invoked with a literal "--file <path>" payload (fm-send had no --file flag,
# so the flag leaked into the message), and every send failed with
# "text not sent ... (tmux send failed)" because `tmux send-keys -l "<--...>"`
# parses the leading-dash TEXT as FLAGS ("invalid flag", exit 1) and types
# nothing - while the composer stayed visibly free. The fix ends option
# parsing before the payload with `--` in every literal/text send site.
# These tests pin that argv shape hermetically (stubbed tmux + sleep): the
# literal payload must always arrive as ONE argument AFTER a bare `--`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmux-submit-dash-literal)

# Fake tmux: records EVERY argument of every send-keys invocation, one per line,
# into $FM_SEND_KEYS_LOG (the single literal send is lines 1..5, later Enter
# retries follow), touches $FM_SENT_ONCE when a submit Enter arrives, and
# answers every composer read with a proven-empty boxed composer so the submit
# confirms on the first read.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    printf '%s\n' "$@" >> "${FM_SEND_KEYS_LOG:?}"
    [ "${*: -1}" = Enter ] && : > "${FM_SENT_ONCE:?}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
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

# assert_literal_send <log> <expected-text> <label>: the FIRST send-keys block
# (line 1 records the command word itself) must be exactly
# [send-keys, -t, <target>, -l, --, <text>] before any Enter retry lines.
assert_literal_send() {
  local log=$1 expected=$2 label=$3 got
  got=$(sed -n '1,6p' "$log" | tr '\n' '|')
  [ "$got" = "send-keys|-t|win|-l|--|$expected|" ] \
    || fail "$label: literal send argv mismatch, got '$got'"
}

test_submit_core_dash_leading_text_reaches_pane_verbatim() {
  local dir fb log once vfile text
  dir="$TMP_ROOT/dash-lead"; fb=$(make_stubs "$dir")
  log="$dir/keys.log"; once="$dir/sent-once"; vfile="$dir/verdict"
  text='--file /home/captain/data/steers/steer.md'
  : > "$log"
  PATH="$fb:$PATH" FM_SEND_KEYS_LOG="$log" FM_SENT_ONCE="$once" \
    fm_tmux_submit_core "win" "$text" 3 0.05 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "dash-leading text should submit cleanly, got '$(cat "$vfile")'"
  assert_literal_send "$log" "$text" "dash-leading text"
  pass "fm_tmux_submit_core: dash-leading text is typed verbatim behind --"
}

test_submit_core_plain_text_keeps_shape() {
  local dir fb log once vfile
  dir="$TMP_ROOT/plain"; fb=$(make_stubs "$dir")
  log="$dir/keys.log"; once="$dir/sent-once"; vfile="$dir/verdict"
  : > "$log"
  PATH="$fb:$PATH" FM_SEND_KEYS_LOG="$log" FM_SENT_ONCE="$once" \
    fm_tmux_submit_core "win" "plain steer text" 3 0.05 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "plain text should still submit cleanly, got '$(cat "$vfile")'"
  assert_literal_send "$log" "plain steer text" "plain text"
  pass "fm_tmux_submit_core: plain text keeps the same one-payload shape"
}

test_send_literal_adapter_guards_dash_text() {
  local dir fb log
  dir="$TMP_ROOT/literal"; fb=$(make_stubs "$dir")
  log="$dir/keys.log"; touch "$dir/sent-once"
  FM_BACKEND_LIB_DIR="$ROOT/bin" FM_SEND_KEYS_LOG="$log" PATH="$fb:$PATH" \
    bash -c '. "$1/bin/backends/tmux.sh"; fm_backend_tmux_send_literal "win" "--leading-dash payload"' _ "$ROOT" \
    || fail "fm_backend_tmux_send_literal should succeed with dash-leading text"
  assert_literal_send "$log" "--leading-dash payload" "adapter literal"
  pass "fm_backend_tmux_send_literal: dash-leading text stays behind --"
}

test_fm_send_dash_message_end_to_end() {
  local dir fb log msg rc got
  dir="$TMP_ROOT/e2e"; mkdir -p "$dir/state"; fb=$(make_stubs "$dir")
  log="$dir/keys.log"
  # An explicit backend target is the typed-plane path: a task selector would
  # ride the durable inbox plane since main's two-plane fm-send, and its
  # message body never crosses send-keys at all. The dash-leading payload
  # class this regression pins lives on the typed plane, so the e2e drives it
  # through the explicit target escape hatch.
  msg='--flagged-looking steer body'
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
    FM_SEND_KEYS_LOG="$log" FM_SENT_ONCE="$dir/sent-once" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" sess:win "$msg" >/dev/null 2>"$dir/stderr.log"
  rc=$?
  expect_code 0 "$rc" "end-to-end dash-leading send"
  got=$(sed -n '1,6p' "$log" | tr '\n' '|')
  [ "$got" = "send-keys|-t|sess:win|-l|--|$msg|" ] \
    || fail "end-to-end dash-leading send argv mismatch, got '$got'"
  pass "fm-send: dash-leading message delivers end to end (regression)"
}

test_submit_core_dash_leading_text_reaches_pane_verbatim
test_submit_core_plain_text_keeps_shape
test_send_literal_adapter_guards_dash_text
test_fm_send_dash_message_end_to_end
