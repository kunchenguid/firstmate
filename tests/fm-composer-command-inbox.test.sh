#!/usr/bin/env bash
# tests/fm-composer-command-inbox.test.sh - integration tests for the arrival
# path bin/fm-inbox.sh extends: a captain note that is exactly an allowlisted
# command invocation attempts delivery into this home's own session via
# bin/fm-composer-command-lib.sh, while every other note keeps behaving
# exactly as it does today. Drives the real bin/fm-inbox.sh binary end to end
# against an isolated scratch FM_HOME (no real tmux pane is required for these
# cases - the session-endpoint-unresolved outcome is itself the proof that a
# real delivery attempt fired); tests/fm-composer-command-lib.test.sh covers
# the delivery pipeline's own decision logic once a session IS resolved, and
# the PR description records a real tmux/Claude Code end-to-end demonstration
# on a throwaway scratch session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX_SH="$ROOT/bin/fm-inbox.sh"

run_note() {  # <home> <body>
  env FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
    "$INBOX_SH" note "$2" 2>&1
}

new_home() {  # <name>
  local home="$WORK/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s' "$home"
}

WORK=$(fm_test_tmproot fm-composer-command-inbox)

# --- feature absent: ordinary note behavior is completely unchanged ---------

HOME_OFF=$(new_home off)
out=$(run_note "$HOME_OFF" "/compact")
assert_contains "$out" "queued" "an ordinary note must still be queued when the feature is off"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "the ordinary wake-notification line must still print when the feature is off"
assert_not_contains "$out" "composer command delivery" \
  "no delivery attempt of any kind may run while config/composer-commands is absent"
assert_not_contains "$out" "this home's own session" \
  "no session-resolution attempt of any kind may run while config/composer-commands is absent"
[ ! -e "$HOME_OFF/state/.composer-session-target" ] \
  || fail "no composer-session state may be touched while the feature is off"
pass "fm-inbox.sh note behaves byte-for-byte as today when config/composer-commands is absent, even for /compact"

# --- feature enabled, but the note is not a recognized command -------------

HOME_ON=$(new_home on)
: > "$HOME_ON/config/composer-commands"
out=$(run_note "$HOME_ON" "please compact things eventually")
assert_contains "$out" "queued" "an ordinary note must still be queued when enabled but unrecognized"
assert_not_contains "$out" "this home's own session" \
  "prose that merely mentions a command word must never attempt delivery"
pass "an enabled home leaves an ordinary (non-command) note completely untouched"

out=$(run_note "$HOME_ON" "/compact now please")
assert_not_contains "$out" "this home's own session" \
  "a command invocation with trailing words must never attempt delivery"
pass "a near-miss invocation (extra words) is never recognized as a command"

# --- feature enabled, recognized command, no resolvable session ------------
# No session_start has ever run for this scratch home, so there is no durable
# record - proving the delivery attempt genuinely fired (not skipped) is
# exactly what a clearly reported, distinct refusal demonstrates.

out=$(run_note "$HOME_ON" "/compact")
assert_contains "$out" "queued" "the note itself must still be queued even when delivery is attempted"
assert_contains "$out" "cannot resolve this home's own session with certainty" \
  "a recognized command with no durable session record must report exactly why nothing was delivered"
[ ! -e "$HOME_ON/state/.composer-command-delivered" ] \
  || fail "nothing may be marked delivered when the session could not be resolved"
pass "an enabled home attempts delivery for an exact command invocation and reports why it could not resolve this home's own session"

# --- an unlisted command-shaped note is refused, not delivered --------------

out=$(run_note "$HOME_ON" "/exit")
assert_contains "$out" "queued" "an unlisted command-shaped note is still queued as an ordinary note"
assert_not_contains "$out" "this home's own session" \
  "a command-shaped string outside the allowlist must never attempt delivery"
pass "a command-shaped note outside the allowlist is refused before any session resolution is attempted"

echo "# fm-composer-command-inbox.test.sh: all assertions passed"
