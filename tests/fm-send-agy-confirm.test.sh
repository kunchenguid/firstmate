#!/usr/bin/env bash
# fm-send typed-plane submit-confirm budget for agy targets.
#
# A typed send to an explicit tmux agy endpoint is acknowledged only by the
# submit core's idle-to-busy transition poll: agy's bare `>` composer verdict
# is `unknown` (dead-shell rule), so the poll watching the pane's verified
# `esc to cancel` busy footer is the only proof a landed Enter can get. agy
# renders that footer ~1.5s after Enter for a short steer and ~4s for a
# multi-line brief (live-measured on agy 1.2.1), while the shared default
# confirm budget is 3 retries x 0.4s - so fm-send used to exit 1 "not
# submitted" for a message that landed and ran, inviting a duplicate resend.
# fm-send now gives agy typed targets a longer default budget (20 retries,
# ~8s at the default cadence); an explicit FM_SEND_RETRIES still wins and every
# other harness keeps the
# shared 3-retry default. These tests pin that behavior hermetically (stubbed
# tmux + sleep, no real agent): the fake tmux renders the busy footer only
# from the BUSY_AT-th plain pane capture, so the number of logged 0.4s waits
# stands in for wall-clock latency and each case is deterministic:
#   1. agy target, busy footer at the 5th poll (short-steer latency): the send
#      exits 0 (confirmed idle-to-busy), and the sleep log shows the poll
#      reaching that read.
#   2. agy target, busy footer only at the 15th poll (the live-measured long
#      brief latency): the default budget still reaches it and exits 0.
#   3. agy target with an explicit FM_SEND_RETRIES=3: the operator knob wins
#      and the send keeps the loud exit-1 verdict=unknown refusal.
#   4. agy target whose busy footer never renders: no confirmation is
#      fabricated - exit 1 verdict=unknown.
#   5. claude target, same late-busy pane: the shared 3-retry default is
#      untouched, so the send still exits 1 verdict=unknown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-agy-confirm)

# A fake tmux that models agy's late busy render, plus a fake sleep that
# records every requested duration (one per line) into FM_SLEEP_LOG instead of
# sleeping. The styled capture (-e) always shows agy's idle bare-`>` composer
# (verdict `unknown`); the plain capture - the one fm_pane_busy_state polls -
# shows the idle screen until its BUSY_AT-th call and the verified `esc to
# cancel` busy row from then on. The BUSY_AT threshold is read from the
# per-case dir so cases are independent.
make_stubs() {  # <dir> <busy-at> -> echoes fakebin dir
  local dir=$1 busy_at=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
cnt_file="$dir/plain.count"
case "\${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *cursor_y*) printf '0\n'; exit 0 ;;
        *pane_tty*) printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    styled=0
    for a in "\$@"; do [ "\$a" = -e ] && styled=1; done
    if [ "\$styled" = 1 ]; then
      printf '> \n? for shortcuts\n'
      exit 0
    fi
    n=\$(( \$(cat "\$cnt_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "\$n" > "\$cnt_file"
    if [ "\$n" -ge $busy_at ]; then
      printf '> \n? for shortcuts\n ⏺ 5s · esc to cancel · gemini-3.8-flash-low\n'
    else
      printf '> \n? for shortcuts\n'
    fi
    exit 0 ;;
  list-windows) printf 'win\n'; exit 0 ;;
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

# run_send <harness> <busy-at> <extra-env-assignments...>: build a fresh home
# whose recorded task targets sess:win on the tmux backend with <harness> meta,
# then run the real fm-send typed plane against the stubs. FM_SEND_SETTLE=0
# strips the post-submit pause so the sleep log holds only the popup settle
# plus the 0.4 submit waits, keeping the poll arithmetic visible. FM_ROOT_OVERRIDE
# points at the case dir so fm-guard's tangle check stays silent. Emits
# "rc <exit>" and leaves the send's stderr in $dir/err and the sleep log in
# $dir/sleep.log for the caller to assert on.
run_send() {  # <harness> <busy-at> [env=val ...]
  local harness=$1 busy_at=$2 dir fb log
  shift 2
  dir="$TMP_ROOT/case-$RANDOM-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir" "$busy_at")
  log="$dir/sleep.log"; : > "$log"
  fm_write_meta "$dir/state/agyw.meta" "window=sess:win" "harness=$harness"
  (
    export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
    export PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_SLEEP_LOG="$log"
    for a in "$@"; do eval "export $a"; done
    "$SEND" sess:win 'Append steer1 line to notes.md' 2>"$dir/err"
    printf 'rc %s\n' "$?"
  )
}

# agy, default budget, busy footer renders at the 5th poll (the 6th plain
# capture): the raised default (20 retries) must reach that read and exit 0.
# Under the old shared default (3 retries) this exact shape exited 1
# "verdict=unknown" - the regression this suite pins.
out=$(run_send agy 6)
expect_code 0 "$(printf '%s' "$out" | sed -n 's/^rc //p')" \
  "agy typed send with late busy footer confirms idle-to-busy and exits 0"
grep -q 'not submitted' "$TMP_ROOT"/*/err 2>/dev/null && \
  fail "agy typed send: refusal text present despite confirmed submit"
pass "agy typed send: no not-submitted refusal on confirmed idle-to-busy"
case_dir=$(printf '%s\n' "$TMP_ROOT"/case-* | head -1)
settles=$(grep -cv '^0\.4$' "$case_dir/sleep.log" || true)
waits=$(grep -c '^0\.4$' "$case_dir/sleep.log" || true)
[ "$settles" = 1 ] || fail "agy typed send: expected exactly 1 non-wait sleep (popup settle), got $settles"
[ "$waits" = 5 ] || fail "agy typed send: expected the poll to reach the 5th busy read (5 x 0.4s: Enter wait + 4 poll waits), got $waits"
pass "agy typed send: sleep log shows the confirm poll running to the late busy render"

# agy with an explicit FM_SEND_RETRIES=3: the operator knob wins over the agy
# default, the budget expires before the late footer, and the loud refusal
# boundary is preserved.
out=$(run_send agy 6 'FM_SEND_RETRIES=3')
expect_code 1 "$(printf '%s' "$out" | sed -n 's/^rc //p')" \
  "agy typed send honors an explicit FM_SEND_RETRIES=3"
grep -q 'verdict=unknown' "$TMP_ROOT"/*/err || fail "agy typed send FM_SEND_RETRIES=3: expected verdict=unknown refusal"
pass "agy typed send: explicit FM_SEND_RETRIES=3 keeps the exit-1 verdict=unknown refusal"

# agy whose busy footer never renders: the raised budget must time out into
# the same loud refusal, never fabricate a confirmation.
out=$(run_send agy 999)
expect_code 1 "$(printf '%s' "$out" | sed -n 's/^rc //p')" \
  "agy typed send with no busy footer refuses exit 1"
grep -q 'verdict=unknown' "$TMP_ROOT"/*/err || fail "agy typed send never-busy: expected verdict=unknown refusal"
pass "agy typed send: never-rendering busy footer still refuses with verdict=unknown"

# agy, busy footer renders only at the 15th poll: the live long-brief case.
# The default budget must still reach that read and exit 0; under the shared
# 3-retry default this shape refused for a message that landed.
out=$(run_send agy 16)
expect_code 0 "$(printf '%s' "$out" | sed -n 's/^rc //p')" \
  "agy typed send with long-brief late busy footer confirms and exits 0"
pass "agy typed send: long-brief render (15th poll) still confirms idle-to-busy"

# claude on the identical late-busy pane: the shared 3-retry default is
# untouched, so the same latency still refuses - the raised budget is
# agy-scoped, not a global slowdown.
out=$(run_send claude 6)
expect_code 1 "$(printf '%s' "$out" | sed -n 's/^rc //p')" \
  "claude typed send keeps the shared 3-retry default"
grep -q 'verdict=unknown' "$TMP_ROOT"/*/err || fail "claude typed send: expected verdict=unknown refusal"
pass "claude typed send: late busy footer still refuses (agy budget is agy-scoped)"
