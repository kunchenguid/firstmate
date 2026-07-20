#!/usr/bin/env bash
# tmux/codex boot guard.
#
# Codex can briefly show pre-composer UI such as an update prompt or a
# model-loading banner. The tmux send primitive must wait for that state to clear
# before typing, and must fail distinctly if the pane never becomes ready.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-tmux-boot)

make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state="${FM_FAKE_STATE:?FM_FAKE_STATE unset}"
sent="${FM_FAKE_SENT:-/dev/null}"
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'
    exit 0 ;;
  capture-pane)
    reads=0
    [ -f "$state.reads" ] && reads=$(cat "$state.reads")
    reads=$((reads + 1))
    printf '%s\n' "$reads" > "$state.reads"
    if [ "${FM_FAKE_ALWAYS_BOOT:-0}" = 1 ]; then
      cat "$state.boot"
    elif [ "$reads" -le "${FM_FAKE_BOOT_READS:-0}" ]; then
      cat "$state.boot"
    else
      cat "$state.ready"
    fi
    exit 0 ;;
  send-keys)
    shift
    text=""; lit=0; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      printf '[ENTER]\n' >> "$sent"
    elif [ "$lit" = 1 ]; then
      printf '%s\n' "$text" >> "$sent"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

write_fixture() {  # <dir>
  local dir=$1
  cat > "$dir/state.boot" <<'EOF'
╭──────────────────────────────────────────────────────╮
│ >_ OpenAI Codex (v0.136.0)                           │
│                                                      │
│ model:     loading   /model to change                │
│ directory: /tmp/firstmate                            │
╰──────────────────────────────────────────────────────╯
EOF
  printf '│ > │\n' > "$dir/state.ready"
}

test_boot_state_detected_causes_deferred_send() {
  local dir fb sent verdict
  dir="$TMP_ROOT/deferred"; mkdir -p "$dir"
  write_fixture "$dir"
  fb=$(make_fake_tmux "$dir")
  sent="$dir/sent.log"; : > "$sent"
  verdict=$(PATH="$fb:$PATH" FM_FAKE_STATE="$dir/state" FM_FAKE_SENT="$sent" \
    FM_FAKE_ALWAYS_BOOT=1 FM_TMUX_BOOT_WAIT_SECS=0 \
    fm_tmux_submit_core "win" "hello captain" 2 0 0)
  [ "$verdict" = send-deferred ] || fail "booting pane should report send-deferred, got '$verdict'"
  [ ! -s "$sent" ] || fail "booting pane received typed text"$'\n'"$(cat "$sent")"
  pass "tmux send: boot-state is detected and the send is deferred before typing"
}

test_boot_resolves_then_send_proceeds() {
  local dir fb sent verdict
  dir="$TMP_ROOT/resolves"; mkdir -p "$dir"
  write_fixture "$dir"
  fb=$(make_fake_tmux "$dir")
  sent="$dir/sent.log"; : > "$sent"
  verdict=$(PATH="$fb:$PATH" FM_FAKE_STATE="$dir/state" FM_FAKE_SENT="$sent" \
    FM_FAKE_BOOT_READS=1 FM_TMUX_BOOT_WAIT_SECS=2 FM_TMUX_BOOT_POLL_SLEEP=1 \
    fm_tmux_submit_core "win" "hello captain" 2 0 0)
  [ "$verdict" = empty ] || fail "send should proceed after boot clears, got '$verdict'"
  grep -Fx 'hello captain' "$sent" >/dev/null || fail "text was not typed after boot cleared"
  grep -Fx '[ENTER]' "$sent" >/dev/null || fail "Enter was not sent after text"
  pass "tmux send: boot-state clearing lets the send proceed"
}

test_fm_send_reports_persistent_boot_distinctly() {
  local dir fb home sent err rc
  dir="$TMP_ROOT/fm-send"; mkdir -p "$dir"
  write_fixture "$dir"
  fb=$(make_fake_tmux "$dir")
  home="$dir/home"; mkdir -p "$home/state"
  sent="$dir/sent.log"; err="$dir/send.err"; : > "$sent"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_FAKE_STATE="$dir/state" \
    FM_FAKE_SENT="$sent" FM_FAKE_ALWAYS_BOOT=1 FM_TMUX_BOOT_WAIT_SECS=0 \
    "$ROOT/bin/fm-send.sh" sess:win "hello captain" >/dev/null 2>"$err"
  rc=$?
  expect_code 2 "$rc" "fm-send persistent boot"
  grep -F 'send-deferred: pane booting' "$err" >/dev/null \
    || fail "fm-send did not report the distinct booting failure: $(cat "$err")"
  [ ! -s "$sent" ] || fail "fm-send typed into a persistently booting pane"
  pass "fm-send: persistent boot exits distinctly without typing"
}

test_boot_state_detected_causes_deferred_send
test_boot_resolves_then_send_proceeds
test_fm_send_reports_persistent_boot_distinctly
