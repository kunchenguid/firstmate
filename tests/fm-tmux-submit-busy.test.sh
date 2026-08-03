#!/usr/bin/env bash
# tests/fm-tmux-submit-busy.test.sh - regression: busy pane + pending composer
# after Enter retries must return "empty" (message queued), not "pending".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_submit_mock() {
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
  capture-pane)
    queue_probe=1
    for a in "$@"; do [ "$a" = -e ] && queue_probe=0; done
    if [ "$queue_probe" = 1 ] && [ "${FM_FAKE_QUEUE_PROBE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    if [ "$queue_probe" = 1 ] && [ -n "${FM_FAKE_QUEUE_CLEAR_ON_RESCAN:-}" ]; then
      count=$(( $(cat "$FM_FAKE_QUEUE_CLEAR_ON_RESCAN" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$count" > "$FM_FAKE_QUEUE_CLEAR_ON_RESCAN"
      if [ "$count" -gt 1 ]; then
        printf '╭─────╮\n│ >   │\n╰─────╯\n'
        exit 0
      fi
    fi
    cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) ;; Enter) is_enter=1 ;; esac; shift
    done
    if [ "$is_enter" = 1 ]; then
      [ -z "${FM_FAKE_SENT:-}" ] || printf 'Enter\n' >> "$FM_FAKE_SENT"
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$COMPOSER"
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_busy_pane_pending_returns_empty() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-accepted"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  # Pre-check: composer state should be pending (via function, not $()).
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "pre-check: composer state expected pending, got '$(cat "$vfile")'"
  # Now test the submit - write verdict to file to avoid nested $().
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane pending should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "proven pending should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns empty (message queued)"
}

test_idle_pane_pending_returns_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "idle-pane pending should return pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)"
}

test_busy_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy pane clears composer on first Enter - returns empty"
}

test_idle_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "idle-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane clears composer on first Enter - returns empty as before"
}

test_busy_pane_unknown_stays_unknown() {
  local dir fakebin composer vfile
  dir="$TMP_ROOT/busy-unknown"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "a busy pane must not convert an unsafe composer to empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy conversion is limited to proven pending input"
}

test_busy_pane_ambiguous_pending_retries_without_conversion() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-ambiguous-pending"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  : > "$sent"
  printf '╭────────────╮\n│ > fix  │\n╰────────────╯\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "ambiguous composer text should be pending-unproven, got '$(cat "$vfile")'"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "a busy pane must not convert pending-unproven to empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "pending-unproven should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: pending-unproven retries without busy conversion"
}

test_unrecognized_state_skips_busy_conversion() {
  local dir fakebin composer busy_called vfile
  dir="$TMP_ROOT/unrecognized-state"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  busy_called="$dir/busy-called"
  vfile="$dir/verdict"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  (
    # shellcheck disable=SC2329
    fm_tmux_composer_state() { printf 'future-state'; }
    # shellcheck disable=SC2329
    fm_pane_is_busy() { touch "$busy_called"; return 0; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  ) || fail "unrecognized-state submit check failed"
  [ "$(cat "$vfile")" = future-state ] \
    || fail "unrecognized state should be preserved, got '$(cat "$vfile")'"
  [ ! -e "$busy_called" ] \
    || fail "unrecognized state must not trigger busy conversion"
  pass "fm_tmux_submit_enter_core: unrecognized states skip busy conversion"
}

test_claude_busy_signature_uses_real_capture_shapes() {
  local dir fakebin composer
  dir="$TMP_ROOT/claude-signature"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  pane_busy() {
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy "$2" "$3"' \
      _ "$ROOT" "$1" "${2:-}"
  }

  # Live Claude 2.1.220 capture 1: spinner glyph and word from one turn.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 1 should be busy"

  # Live Claude 2.1.220 capture 2: a later turn with a changed glyph and word.
  printf '✽ Proofing… (5s · thinking with high effort)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 2 should be busy"

  # Real idle Claude capture shape from the verified pane sample.
  printf '✻ Worked for 31s\n' > "$composer"
  pane_busy idle claude && fail "Claude Worked-for capture must be idle"

  # The new signature is Claude-scoped and must not widen the shared default.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens)\n' > "$composer"
  pane_busy live && fail "Claude signature must not match without the Claude harness"

  # Each verified harness must use only its own signature.
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore OpenCode's interrupt footer"
  printf 'Working...\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore Pi's Working footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore OpenCode's interrupt footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross opencode && fail "OpenCode must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross pi && fail "Pi must ignore OpenCode's interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy cross grok && fail "Grok must ignore Claude's legacy interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy own codex || fail "Codex's escape footer should be busy"
  printf 'esc interrupt\n' > "$composer"
  pane_busy own opencode || fail "OpenCode's interrupt footer should be busy"

  # No harness keeps the historical combined-pattern compatibility fallback.
  printf 'Working...\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Pi's shared signature"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Grok's shared signature"

  # A supplied harness must never use another harness's signature. This is
  # particularly important for Kimi: its idle key-tip rotation can include the
  # same cancel token Grok uses to mean busy.
  printf 'Working...\n' > "$composer"
  pane_busy unknown kimi && fail "Kimi must ignore Pi's Working footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy unknown kimi && fail "idle Kimi must ignore Grok's cancel footer"

  # Older Claude Code and the existing Pi and Grok signatures remain unchanged.
  printf 'esc to interrupt\n' > "$composer"
  pane_busy old-claude claude || fail "older Claude escape footer should be busy"
  printf 'Working...\n' > "$composer"
  pane_busy pi pi || fail "Pi Working footer should be busy"
  pane_busy pi-signed pi-signed || fail "pi-signed should share Pi's exact Working footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy grok grok || fail "Grok cancel footer should be busy"
  pass "fm_pane_is_busy: Claude spinner is scoped, multi-frame, and backward-compatible"
}

# Parked-lane numbered queue: empty composer + `#N [fm-from-firstmate]` must
# never report empty. Exhaust reports queued-unsubmitted; a later clear succeeds.
test_queued_unsubmitted_exhausted_fails_loud() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/queued-unsubmitted-fail"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  # Empty composer box with a numbered firstmate queue item still present.
  printf '#1 [fm-from-firstmate]corr=abc do the work\n╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  : > "$sent"
  # Persist: Enter never clears the queue in this scenario.
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = queued-unsubmitted ] \
    || fail "numbered queue surviving Enter retries should be queued-unsubmitted, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "queued-unsubmitted should consume the Enter retry budget"
  pass "fm_tmux_submit_enter_core: parked numbered queue exhausts as queued-unsubmitted"
}

test_queued_unsubmitted_retry_succeeds() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/queued-unsubmitted-retry"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '#1 [fm-from-firstmate]corr=abc do the work\n╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  : > "$sent"
  # Swallow only the first Enter; later Enters clear the composer file to empty
  # box without the queue marker (mock's default clear path).
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=0 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "a later Enter that clears the numbered queue should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -ge 2 ] \
    || fail "queued-unsubmitted retry-success should send more than one Enter"
  pass "fm_tmux_submit_enter_core: bounded Enter retry clears a parked numbered queue"
}

test_queued_unsubmitted_blocks_busy_queue_conversion() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/queued-blocks-busy"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  # Proven pending in composer is the opencode busy-queue shape; a numbered
  # queue marker must still win and fail loud rather than convert to empty.
  printf '#1 [fm-from-firstmate]corr=abc fix it\n╭────────────╮\n│ > fix it   │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = queued-unsubmitted ] \
    || fail "busy conversion must not hide a numbered queue item, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: numbered queue overrides opencode busy-queue empty conversion"
}

test_unreadable_queue_probe_never_reports_delivered() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/queued-probe-unreadable"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_QUEUE_PROBE_FAIL=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "an unreadable queue probe must return unknown, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: unreadable queue verification never reports delivered"
}

test_queue_clear_on_exhaustion_rescan_reports_empty() {
  local dir fakebin composer sent vfile probe_count
  dir="$TMP_ROOT/queued-clear-on-rescan"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  probe_count="$dir/probe-count"
  printf '#1 [fm-from-firstmate]corr=abc do the work\n╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_QUEUE_CLEAR_ON_RESCAN="$probe_count" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 1 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "a queue cleared on the exhaustion rescan must return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: exhaustion rescan preserves candidate-empty delivery proof"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_busy_pane_unknown_stays_unknown
test_busy_pane_ambiguous_pending_retries_without_conversion
test_unrecognized_state_skips_busy_conversion
test_claude_busy_signature_uses_real_capture_shapes
test_queued_unsubmitted_exhausted_fails_loud
test_queued_unsubmitted_retry_succeeds
test_queued_unsubmitted_blocks_busy_queue_conversion
test_unreadable_queue_probe_never_reports_delivered
test_queue_clear_on_exhaustion_rescan_reports_empty
