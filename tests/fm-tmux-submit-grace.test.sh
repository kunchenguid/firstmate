#!/usr/bin/env bash
# tests/fm-tmux-submit-grace.test.sh - regression: a composer that stays
# "pending" through the normal Enter retries AND the busy fallback, but
# clears during the bounded post-exhaustion grace window, must return the
# cleared state (a slow/loaded delivery still catching up), not the hard
# "pending" (swallowed) verdict. A pane that never clears must still return
# "pending" after the grace window - the fix must not weaken genuine-swallow
# detection. See data/fm-send-false-negative-q4/report.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-grace.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_grace_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys) exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  # Fake sleep: logs every requested duration, and only when the duration
  # matches the grace window ($FM_SEND_GRACE) does it clear the composer -
  # simulating a delivery that finishes DURING the grace sleep, not before
  # or after it.
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
: "${FM_SLEEP_LOG:?}" "${FM_FAKE_COMPOSER:?}"
printf '%s\n' "$1" >> "$FM_SLEEP_LOG"
if [ -n "${FM_SEND_GRACE:-}" ] && [ "$1" = "$FM_SEND_GRACE" ] \
   && [ "${FM_FAKE_CLEAR_ON_GRACE:-0}" = 1 ]; then
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$FM_FAKE_COMPOSER"
fi
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

test_grace_recheck_catches_late_delivery() {
  local dir fakebin composer log vfile
  dir="$TMP_ROOT/grace-catches"
  fakebin=$(make_grace_mock "$dir")
  composer="$dir/composer"
  log="$dir/sleep.log"
  vfile="$dir/verdict"
  printf '╭────────────────────────╮\n│ > fix findings 1 and 3 │\n╰────────────────────────╯\n' > "$composer"
  : > "$log"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_SLEEP_LOG="$log" \
    FM_FAKE_PANE_BUSY=0 FM_FAKE_CLEAR_ON_GRACE=1 FM_SEND_GRACE=0.2 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "late delivery during grace should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^0\.2$' "$log")" -eq 1 ] \
    || fail "grace sleep should be requested exactly once, log: $(cat "$log")"
  pass "fm_tmux_submit_enter_core: composer clears during grace window returns empty (late delivery, not a swallow)"
}

test_grace_recheck_preserves_genuine_swallow() {
  local dir fakebin composer log vfile
  dir="$TMP_ROOT/grace-swallow"
  fakebin=$(make_grace_mock "$dir")
  composer="$dir/composer"
  log="$dir/sleep.log"
  vfile="$dir/verdict"
  printf '╭────────────────────────╮\n│ > fix findings 1 and 3 │\n╰────────────────────────╯\n' > "$composer"
  : > "$log"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_SLEEP_LOG="$log" \
    FM_FAKE_PANE_BUSY=0 FM_FAKE_CLEAR_ON_GRACE=0 FM_SEND_GRACE=0.2 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "a pane that never clears must still return pending after grace, got '$(cat "$vfile")'"
  [ "$(grep -c '^0\.2$' "$log")" -eq 1 ] \
    || fail "grace sleep should still be requested exactly once, log: $(cat "$log")"
  pass "fm_tmux_submit_enter_core: pane that never changes still returns pending after grace (genuine swallow preserved)"
}

test_grace_recheck_catches_late_delivery
test_grace_recheck_preserves_genuine_swallow
