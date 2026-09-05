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
    if [ -n "${FM_FAKE_CAPTURE_COUNT:-}" ]; then
      count=0
      [ ! -f "$FM_FAKE_CAPTURE_COUNT" ] || count=$(cat "$FM_FAKE_CAPTURE_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_CAPTURE_COUNT"
      if [ "${FM_FAKE_FAIL_FIRST_CAPTURE:-0}" = 1 ] && [ "$count" -eq 1 ]; then
        exit 1
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
        [ "${FM_FAKE_APPEND_BUSY:-0}" != 1 ] || printf '✻ Working…\n' >> "$COMPOSER"
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

test_wrapped_continuation_retries_swallowed_enter() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/wrapped-continuation-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '❯ wrapped typed input\ncontinues on the next terminal row\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "wrapped input must remain pending after swallowed Enter, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "wrapped input should consume the Enter retry budget"
  pass "fm_tmux_submit_enter_core: wrapped input retains swallowed-Enter retries"
}

test_placeholder_like_bare_input_retries_swallowed_enter() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/placeholder-like-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf 'transcript\n❯ Type a message...\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "placeholder-like bare input must remain pending after swallowed Enter, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "placeholder-like bare input should consume the Enter retry budget"
  pass "fm_tmux_submit_enter_core: placeholder-like bare input retains swallowed-Enter retries"
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

test_failed_baseline_capture_keeps_busy_unknown_unconfirmed() {
  local dir fakebin composer vfile
  dir="$TMP_ROOT/failed-baseline"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    FM_FAKE_CAPTURE_COUNT="$dir/captures" FM_FAKE_FAIL_FIRST_CAPTURE=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_APPEND_BUSY=1 \
    fm_tmux_submit_core "win" "fix" 3 0.05 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "a failed idle-baseline capture must not let a later busy footer confirm delivery, got '$(cat "$vfile")'"
  grep -q 'Working' "$composer" \
    || fail "failed-baseline regression did not render the post-Enter busy footer"
  pass "fm_tmux_submit_core: failed baseline capture disables busy unknown conversion"
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
  # omp (Oh My Pi) renders the TUI line with U+2026 and the headless line with
  # three dots; both are its own signature, and neither Pi nor Codex may borrow
  # the ellipsis form. The status-row spinner cell is its second, independent
  # signal, and an idle status row (identity glyph, no elapsed time) is not busy.
  pane_busy omp omp || fail "omp headless Working... footer should be busy"
  printf ' \xf3\xb1\x8a\xb7 Working\xe2\x80\xa6\n' > "$composer"
  pane_busy omp omp || fail "omp TUI Working… footer should be busy"
  pane_busy omp-ellipsis-pi pi && fail "Pi must not borrow omp's Working… footer"
  pane_busy omp-ellipsis-codex codex && fail "Codex must not borrow omp's Working… footer"
  printf ' \xe2\xa0\xa7 11s  \xc2\xb7 gpt-6-astra\n' > "$composer"
  pane_busy omp-spinner omp || fail "omp braille spinner plus elapsed cell should be busy"
  printf ' \xf3\xb0\xb5\x97  \xc2\xb7 gpt-6-astra \xc2\xb7 36.7%%/41K\n' > "$composer"
  pane_busy omp-idle omp && fail "omp idle status row must not read busy"
  printf 'esc interrupt\n' > "$composer"
  pane_busy omp-cross omp && fail "omp must ignore OpenCode's interrupt footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy grok grok || fail "Grok cancel footer should be busy"
  pass "fm_pane_is_busy: Claude spinner is scoped, multi-frame, and backward-compatible"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_wrapped_continuation_retries_swallowed_enter
test_placeholder_like_bare_input_retries_swallowed_enter
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_busy_pane_unknown_stays_unknown
test_failed_baseline_capture_keeps_busy_unknown_unconfirmed
test_busy_pane_ambiguous_pending_retries_without_conversion
test_unrecognized_state_skips_busy_conversion
test_claude_busy_signature_uses_real_capture_shapes
