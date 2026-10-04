#!/usr/bin/env bash
# OPTIONAL/MANUAL live integration test for the ChatGPT worker loop.
#
# This test is NOT part of normal CI. It runs one real audit consultation
# through the installed codex-chatgpt-web bridge and is opt-in only:
#   FM_CHATGPT_LOOP_LIVE=1 bash tests/fm-chatgpt-loop-live.test.sh
# Default behavior is a clean skip with no live bridge contact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CHATGPT_LOOP_LIVE

LOOP="$ROOT/bin/fm-chatgpt-loop.sh"
TMP_ROOT=$(fm_test_tmproot fm-chatgpt-loop-live)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
export FM_HOME="$HOME_DIR"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_STATE_OVERRIDE="$HOME_DIR/state"

printf 'Summarize in one sentence what a code auditor checks first.\n' > "$TMP_ROOT/objective.txt"

bash "$LOOP" init --task live --objective-file "$TMP_ROOT/objective.txt" >/dev/null
out=$(bash "$LOOP" consult --stage audit --task live 2>"$TMP_ROOT/stderr.txt") || fail "live audit consult failed: $(cat "$TMP_ROOT/stderr.txt")"
[ -n "$out" ] || fail "live audit consult returned empty text"
[ "$(jq -r '.phase' "$HOME_DIR/data/live/chatgpt-loop.json")" = "audit-dispatch" ] || fail "live consult must advance to audit-dispatch"
pass "live audit consultation returns text and advances the loop"
