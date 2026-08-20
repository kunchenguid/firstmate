#!/usr/bin/env bash
# tests/fm-submit-confirm-window.test.sh - regression: a submit core must size
# its confirmation window to the line it submitted.
#
# The bug this pins: every submit core waited a CONSTANT window for its
# confirming evidence, but a harness cannot clear its composer (or start a
# turn) before it has accepted the whole submitted line, and that acceptance
# latency scales with the line's length. A realistic multi-hundred-character
# steer to agy was therefore reported "delivery unconfirmed" after it had
# already landed, which pushed firstmate into recovery against a healthy
# worker.
#
# The fix must not loosen anything: these cases assert BOTH directions - a
# composer that clears late inside the widened window now confirms, and a
# composer that never clears still refuses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Tight sampling and a small cap keep the timed cases fast without changing the
# policy under test: the budget arithmetic is asserted separately at the real
# defaults, which each assertion sets explicitly.
export FM_SUBMIT_CONFIRM_INTERVAL=0.02
export FM_SUBMIT_CONFIRM_MAX=1

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-submit-confirm-window.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

ge() {  # <actual> <floor> <label>
  awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) >= (b + 0)) }' \
    || fail "$3 (got $1, wanted at least $2)"
}
le() {  # <actual> <ceiling> <label>
  awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) <= (b + 0)) }' \
    || fail "$3 (got $1, wanted at most $2)"
}

# --- the budget policy itself ------------------------------------------------

test_budget_without_a_length_is_unchanged() {
  local got
  got=$(fm_submit_confirm_budget 0.4)
  ge "$got" 0.4 "no-length budget must keep the caller's own window"
  le "$got" 0.4 "no-length budget must not widen the caller's own window"
  got=$(fm_submit_confirm_budget 0.4 0)
  le "$got" 0.4 "a zero-length line must keep the caller's own window"
  pass "fm_submit_confirm_budget: a caller with no line length keeps its previous timing"
}

test_budget_covers_measured_acceptance_latency() {
  # Live measurements, agy 1.1.15 through herdr 0.8.2, steering a mid-turn
  # worker (docs/verification/runtime-backends.md "Submit acceptance latency").
  local got
  got=$(FM_SUBMIT_CONFIRM_MAX=10 fm_submit_confirm_budget 0.6 79)
  ge "$got" 0.6 "a short steer must still get at least the caller's window"
  got=$(FM_SUBMIT_CONFIRM_MAX=10 fm_submit_confirm_budget 0.6 307)
  ge "$got" 1.6 "307-character steers were measured accepting at up to 1.58s"
  got=$(FM_SUBMIT_CONFIRM_MAX=10 fm_submit_confirm_budget 0.6 615)
  ge "$got" 7.5 "615-character steers were measured accepting at up to 7.44s"
  pass "fm_submit_confirm_budget: the window covers the measured acceptance latency"
}

test_budget_is_capped() {
  local got
  got=$(FM_SUBMIT_CONFIRM_MAX=10 fm_submit_confirm_budget 0.6 1000000)
  le "$got" 10 "an absurd line must not produce an unbounded window"
  pass "fm_submit_confirm_budget: the window is capped so a caller cannot stall"
}

test_short_window_still_samples_once() {
  local got
  got=$(FM_SUBMIT_CONFIRM_INTERVAL=0.25 fm_submit_confirm_polls 0.05)
  [ "$got" = 1 ] || fail "a window shorter than one interval must collapse to a single sample (got $got)"
  got=$(FM_SUBMIT_CONFIRM_INTERVAL=0.25 fm_submit_confirm_polls 1.5)
  [ "$got" = 6 ] || fail "a widened window must be sampled at the configured interval (got $got)"
  pass "fm_submit_confirm_polls: a sub-interval window keeps the single-read behavior"
}

# --- the shared retry core ---------------------------------------------------
#
# A real fake harness: a composer whose recorded verdict flips from pending to
# empty only after N reads, driven through real processes on disk.

make_fake_composer() {  # <dir> <reads-before-empty> [terminal-verdict]
  local dir=$1 reads=$2 terminal=${3:-empty}
  mkdir -p "$dir"
  printf '0\n' > "$dir/reads"
  printf '%s\n' "$reads" > "$dir/threshold"
  printf '%s\n' "$terminal" > "$dir/terminal"
  : > "$dir/keys"
}

fake_state_fn() {  # <target> [label]
  local dir=$FAKE_DIR count threshold
  count=$(cat "$dir/reads")
  count=$((count + 1))
  printf '%s\n' "$count" > "$dir/reads"
  threshold=$(cat "$dir/threshold")
  if [ "$threshold" -ge 0 ] && [ "$count" -ge "$threshold" ]; then
    cat "$dir/terminal"
  else
    printf 'pending'
  fi
}

fake_send_key_fn() {  # <target> <key> [label]
  printf '%s\n' "$2" >> "$FAKE_DIR/keys"
}

enters_sent() { grep -c . "$FAKE_DIR/keys"; }

test_late_clearing_composer_now_confirms() {
  local verdict
  FAKE_DIR="$TMP_ROOT/late"; export FAKE_DIR
  make_fake_composer "$FAKE_DIR" 20 empty
  verdict=$(fm_composer_submit_retry_core fake_send_key_fn fake_state_fn win 3 0.05 '' 400)
  [ "$verdict" = empty ] || fail "a composer clearing late inside the sized window must confirm (got '$verdict')"
  [ "$(enters_sent)" = 1 ] || fail "confirming inside the first window must not send extra Enters (sent $(enters_sent))"
  pass "submit core: a composer that clears late inside the sized window confirms on one Enter"
}

test_same_composer_without_the_length_still_fails() {
  # The regression pin: identical harness behavior, only the line length
  # withheld, reproduces the constant-window verdict the bug shipped.
  local verdict
  FAKE_DIR="$TMP_ROOT/late-unsized"; export FAKE_DIR
  make_fake_composer "$FAKE_DIR" 20 empty
  verdict=$(fm_composer_submit_retry_core fake_send_key_fn fake_state_fn win 3 0.05)
  [ "$verdict" = pending ] || fail "without the line length the constant window must still expire (got '$verdict')"
  pass "submit core: the same harness under a constant window still reports pending (the shipped bug)"
}

test_composer_that_never_clears_still_refuses() {
  local verdict
  FAKE_DIR="$TMP_ROOT/never"; export FAKE_DIR
  make_fake_composer "$FAKE_DIR" -1 empty
  verdict=$(fm_composer_submit_retry_core fake_send_key_fn fake_state_fn win 3 0.05 '' 400)
  [ "$verdict" = pending ] || fail "a composer that never clears must still report pending (got '$verdict')"
  [ "$(enters_sent)" = 3 ] || fail "a genuine swallow must still spend its Enter retries (sent $(enters_sent))"
  pass "submit core: a composer that never clears still refuses - the check is not loosened"
}

test_unreadable_composer_still_refuses_immediately() {
  local verdict
  FAKE_DIR="$TMP_ROOT/unknown"; export FAKE_DIR
  make_fake_composer "$FAKE_DIR" 3 unknown
  verdict=$(fm_composer_submit_retry_core fake_send_key_fn fake_state_fn win 3 0.05 '' 400)
  [ "$verdict" = unknown ] || fail "an unreadable composer must stay a loud refusal (got '$verdict')"
  [ "$(enters_sent)" = 1 ] || fail "an unreadable composer must not be retried into (sent $(enters_sent))"
  pass "submit core: an unreadable composer is still a loud refusal, not a retry"
}

# --- the tmux core, through a real fake tmux --------------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

fm_pane_is_busy() { [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]; }

make_fake_tmux() {  # <dir>
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_STATE:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane)
    count=$(cat "$STATE/reads")
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE/reads"
    threshold=$(cat "$STATE/threshold")
    if [ "$threshold" -ge 0 ] && [ "$count" -ge "$threshold" ]; then
      printf '╭─────╮\n│ >   │\n╰─────╯\n'
    else
      printf '╭─────────────────────╮\n│ > still holding it  │\n╰─────────────────────╯\n'
    fi
    exit 0 ;;
  send-keys)
    shift
    is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) printf 'LITERAL\n' >> "$STATE/keys" ;; Enter) is_enter=1 ;; esac
      shift
    done
    [ "$is_enter" = 0 ] || printf 'Enter\n' >> "$STATE/keys"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_core_confirms_a_late_clearing_composer() {
  local dir fakebin verdict
  dir="$TMP_ROOT/tmux-late"
  fakebin=$(make_fake_tmux "$dir")
  make_fake_composer "$dir/state" 20 empty
  verdict=$(
    PATH="$fakebin:$PATH" FM_FAKE_STATE="$dir/state" \
      fm_tmux_submit_enter_core win 3 0.05 1 400 2>/dev/null
  )
  [ "$verdict" = empty ] || fail "tmux core must confirm a composer clearing inside the sized window (got '$verdict')"
  [ "$(grep -c LITERAL "$dir/state/keys" || true)" = 0 ] || fail "tmux core must never retype"
  pass "fm_tmux_submit_enter_core: a composer clearing late inside the sized window confirms"
}

test_tmux_core_still_refuses_a_composer_that_never_clears() {
  local dir fakebin verdict
  dir="$TMP_ROOT/tmux-never"
  fakebin=$(make_fake_tmux "$dir")
  make_fake_composer "$dir/state" -1 empty
  verdict=$(
    PATH="$fakebin:$PATH" FM_FAKE_STATE="$dir/state" FM_FAKE_PANE_BUSY=0 \
      fm_tmux_submit_enter_core win 3 0.05 '' 400 2>/dev/null
  )
  [ "$verdict" = pending ] || fail "tmux core must still refuse a composer that never clears (got '$verdict')"
  [ "$(grep -c LITERAL "$dir/state/keys" || true)" = 0 ] || fail "tmux core must never retype"
  pass "fm_tmux_submit_enter_core: a composer that never clears still refuses"
}

test_budget_without_a_length_is_unchanged
test_budget_covers_measured_acceptance_latency
test_budget_is_capped
test_short_window_still_samples_once
test_late_clearing_composer_now_confirms
test_same_composer_without_the_length_still_fails
test_composer_that_never_clears_still_refuses
test_unreadable_composer_still_refuses_immediately
test_tmux_core_confirms_a_late_clearing_composer
test_tmux_core_still_refuses_a_composer_that_never_clears
