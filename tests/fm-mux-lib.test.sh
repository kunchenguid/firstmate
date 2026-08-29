#!/usr/bin/env bash
# Behavior tests for the multiplexer seam (bin/fm-mux-lib.sh).
#
# The seam exists so firstmate can drive panes through something other than
# tmux. Its whole value rests on one property: EVERY driver honours the SAME
# contract, so a caller written against the seam works under either. These
# cases pin that contract from both sides, plus the driver-selection rules.
#
# Both drivers are exercised over fakebins - no real tmux window and no real
# herdr pane is created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-mux-lib.sh
. "$ROOT/bin/fm-mux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mux)

# Fakebins that record their argv so we can assert on the CALL, not just output.
make_fakes() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  capture-pane) cat "${PANE_FILE:-/dev/null}" 2>/dev/null ;;
esac
exit "${TMUX_RC:-0}"
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "tab create")   printf 'created tab w9:t7\n' ;;
  "agent prompt") [ "${HERDR_BLOCKED:-0}" = 1 ] && { echo "error: agent_blocked" >&2; exit 1; }; exit "${HERDR_RC:-0}" ;;
  "agent read")   cat "${PANE_FILE:-/dev/null}" 2>/dev/null ;;
  "agent get")    printf 'name: crew\nstatus: %s\n' "${AGENT_STATE:-idle}" ;;
esac
exit "${HERDR_RC:-0}"
SH
  chmod +x "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}
FB=$(make_fakes "$TMP_ROOT"); PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls.txt"; export CALLS
reset_calls() { : > "$CALLS"; }

# --- driver selection -------------------------------------------------------

# An explicit FM_MUX always wins. This is the rollback switch: if the herdr
# driver misbehaves in production, FM_MUX=tmux restores today's behaviour.
test_explicit_fm_mux_wins() {
  local got
  got=$(FM_MUX=tmux HERDR_ENV=1 fm_mux_driver)
  if [ "$got" = tmux ]; then
    pass "FM_MUX=tmux overrides an in-herdr environment"
  else
    fail "FM_MUX ignored: got '$got'"
  fi
}

# Absent an explicit choice, only a genuine in-herdr environment selects herdr.
test_autodetect_requires_herdr_env() {
  local a b
  a=$(FM_MUX="" HERDR_ENV=1 fm_mux_driver)
  b=$(FM_MUX="" HERDR_ENV="" fm_mux_driver)
  if [ "$a" = herdr ] && [ "$b" = tmux ]; then
    pass "autodetect: herdr inside herdr, tmux otherwise"
  else
    fail "autodetect wrong: in-herdr='$a' outside='$b'"
  fi
}

# An unknown driver must fail loudly rather than silently doing nothing.
test_unknown_driver_refuses() {
  if FM_MUX=screen fm_mux_read foo >/dev/null 2>&1; then
    fail "unknown driver silently accepted"
  else
    pass "unknown FM_MUX driver is refused, not ignored"
  fi
}

# --- the shared contract, honoured by both drivers --------------------------

# A target is OPAQUE. Each driver mints its own shape; callers pass it back
# verbatim. If this breaks, the drivers stop being swappable.
test_new_window_returns_opaque_target() {
  local t h
  t=$(FM_MUX=tmux  fm_mux_new_window firstmate fm-x /tmp)
  h=$(FM_MUX=herdr fm_mux_new_window firstmate fm-x /tmp)
  [ "$t" = "firstmate:fm-x" ] || fail "tmux target wrong: '$t'"
  [ "$h" = "w9:t7" ]          || fail "herdr target wrong: '$h'"
  pass "each driver mints its own opaque target"
}

# send must DELIVER AND SUBMIT. tmux needs two calls plus a sleep because it
# has no acknowledgment; herdr does it in one acknowledged call. Same contract,
# different cost - that difference is the whole reason for the seam.
test_send_delivers_and_submits() {
  reset_calls
  FM_MUX=tmux FM_MUX_ENTER_SLEEP=0 fm_mux_send firstmate:fm-x "hello"
  grep -q -- "-l hello" "$CALLS" || fail "tmux send did not type the text"
  grep -q "Enter"       "$CALLS" || fail "tmux send did not submit"
  reset_calls
  FM_MUX=herdr fm_mux_send w9:t7 "hello"
  grep -q "agent prompt w9:t7 hello --wait" "$CALLS" \
    || fail "herdr send did not use the acknowledged prompt path"
  pass "both drivers deliver AND submit; herdr does it in one acknowledged call"
}

# A blocked agent must be REFUSED, not written over. herdr >= 0.8.2 reports
# agent_blocked; typing into an approval dialog is how a prompt gets eaten.
test_blocked_agent_is_refused_distinctly() {
  local rc
  HERDR_BLOCKED=1 FM_MUX=herdr fm_mux_send w9:t7 "hello" 2>/dev/null; rc=$?
  if [ "$rc" = 3 ]; then
    pass "blocked agent returns a distinct code, not a generic failure"
  else
    fail "blocked agent returned $rc, expected 3"
  fi
}

# is_busy is where the drivers genuinely differ: tmux pattern-matches rendered
# text; herdr reads a real state. Both must answer the same question.
test_is_busy_agrees_across_drivers() {
  PANE_FILE="$TMP_ROOT/pane.txt"; export PANE_FILE
  printf 'esc to interrupt\n' > "$PANE_FILE"
  FM_MUX=tmux fm_mux_is_busy firstmate:fm-x || fail "tmux: missed a busy pane"
  printf 'all done\n' > "$PANE_FILE"
  FM_MUX=tmux fm_mux_is_busy firstmate:fm-x && fail "tmux: called an idle pane busy"
  AGENT_STATE=working FM_MUX=herdr fm_mux_is_busy w9:t7 || fail "herdr: missed working"
  AGENT_STATE=idle    FM_MUX=herdr fm_mux_is_busy w9:t7 && fail "herdr: called idle busy"
  pass "is_busy agrees across drivers (regex vs real state)"
}

test_read_returns_pane_text_under_both() {
  PANE_FILE="$TMP_ROOT/pane2.txt"; export PANE_FILE
  printf 'line-one\nline-two\n' > "$PANE_FILE"
  FM_MUX=tmux  fm_mux_read firstmate:fm-x | grep -q line-two || fail "tmux read lost content"
  FM_MUX=herdr fm_mux_read w9:t7          | grep -q line-two || fail "herdr read lost content"
  pass "read returns pane text under both drivers"
}

# A driver that cannot create a window must report failure, not hand back a
# target that does not exist - that is how firstmate ends up recording a meta
# for a pane holding nothing.
test_new_window_failure_is_reported() {
  if TMUX_RC=1 FM_MUX=tmux fm_mux_new_window firstmate fm-x /tmp >/dev/null 2>&1; then
    fail "tmux driver returned success on a failed window create"
  else
    pass "a failed window create is reported, not papered over"
  fi
}

test_explicit_fm_mux_wins
test_autodetect_requires_herdr_env
test_unknown_driver_refuses
test_new_window_returns_opaque_target
test_send_delivers_and_submits
test_blocked_agent_is_refused_distinctly
test_is_busy_agrees_across_drivers
test_read_returns_pane_text_under_both
test_new_window_failure_is_reported
