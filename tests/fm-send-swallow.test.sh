#!/usr/bin/env bash
# fm-send swallow detection (regression for the wrapped-line gap).
#
# When fm_tmux_submit_core reports the composer still pending after a submit,
# fm-send.sh distinguishes a genuine swallowed Enter (our text is still in the
# composer -> exit 1) from a WSL phantom-pending read (the composer holds
# something else -> warning + exit 0). The composer row it inspects is the
# single cursor row, so a long steer that WRAPS leaves only its tail fragment
# there. The forward substring test ("whole sent text on the cursor row") then
# misses, and a real swallow used to be reported as delivered. These tests pin:
#   1. a short swallow (whole line on the cursor row) still exits non-zero,
#   2. a wrapped swallow (only the tail fragment on the cursor row) exits
#      non-zero too (the regression), and
#   3. an unrelated leftover (phantom pending / captain text) stays a warning
#      with exit 0.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-tests.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# A fake tmux whose composer (the styled cursor row) is fixed by FM_FAKE_COMPOSER.
# capture-pane -e (single cursor row) serves it verbatim; a plain capture-pane
# (the busy-tail scan) serves a non-busy line so fm_pane_is_busy is false.
# send-keys and display-message succeed; cursor_y is 0.
make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0
    for a in "$@"; do [ "$a" = "-e" ] && has_e=1; done
    if [ "$has_e" = 1 ]; then
      printf '%s\n' "${FM_FAKE_COMPOSER:-}"
    else
      printf 'idle pane, no busy footer\n'
    fi
    exit 0 ;;
  send-keys) exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

FAKEBIN=$(make_fake_tmux "$TMP_ROOT")

# Run fm-send against the fake tmux with an isolated, empty FM_HOME (no .meta,
# so fm-guard stays silent) and fast, deterministic timings.
run_send() {  # <composer-line> <text...> ; sets RC
  local composer=$1; shift
  FM_FAKE_COMPOSER=$composer \
  FM_ROOT_OVERRIDE="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
  FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_AMBIGUOUS_SETTLE=0 \
  PATH="$FAKEBIN:$PATH" \
    "$SEND" fake:pane "$@" >/dev/null 2>&1
  RC=$?
}

MSG="please run the full regression suite now across every supported platform"

test_short_swallow_fails() {
  run_send "deploy now" deploy now
  [ "$RC" -ne 0 ] || fail "short swallow (whole line in composer) was reported as delivered"
  pass "fm-send: a short swallowed steer exits non-zero"
}

test_wrapped_swallow_fails() {
  # The cursor row holds only the wrapped TAIL of the sent message - the forward
  # whole-line test misses it; the reverse fragment test must still catch it.
  run_send "supported platform" "$MSG"
  [ "$RC" -ne 0 ] || fail "wrapped swallow (tail fragment in composer) was reported as delivered"
  pass "fm-send: a wrapped swallowed steer exits non-zero"
}

test_unrelated_pending_is_delivered() {
  # Leftover text that is NOT part of the sent message = phantom pending; treat
  # as delivered so a WSL false-positive never turns a real steer into an error.
  run_send "captain half-typed note" "$MSG"
  [ "$RC" -eq 0 ] || fail "unrelated leftover composer text was wrongly reported as a swallow"
  pass "fm-send: unrelated pending text downgrades to delivered"
}

test_short_swallow_fails
test_wrapped_swallow_fails
test_unrelated_pending_is_delivered
printf 'all fm-send swallow tests passed\n'
