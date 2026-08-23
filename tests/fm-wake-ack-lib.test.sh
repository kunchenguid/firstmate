#!/usr/bin/env bash
# tests/fm-wake-ack-lib.test.sh - the one owner of the WAKE_ACK_REQUIRED line
# must emit the byte-stable legacy wording and parse it back losslessly:
#
#   1. emit -> parse round-trip for both fields.
#   2. The emitted line is byte-identical to the legacy printf wording, and a
#      hard-coded legacy capture parses (pins compatibility with the six
#      production parsers and the wake tests).
#   3. Malformed lines parse to nothing (missing generation, non-numeric
#      through, trailing garbage).
#   4. With several lines in one capture, the LAST one wins.
#
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-wake-ack-lib.sh
. "$REPO/bin/fm-wake-ack-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# --- 1. round-trip ---------------------------------------------------------
fm_wake_ack_line 7 "gen-2026.08.23_abc" > "$TMP/cap"
[ "$(fm_wake_ack_parse_through "$TMP/cap")" = "7" ] && ok "through round-trips" \
  || fail "through must round-trip"
[ "$(fm_wake_ack_parse_generation "$TMP/cap")" = "gen-2026.08.23_abc" ] && ok "generation round-trips" \
  || fail "generation must round-trip"

# --- 2. byte-stable legacy wording ----------------------------------------
legacy='WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 42 --recovery-generation g1787.tok'
[ "$(fm_wake_ack_line 42 g1787.tok)" = "$legacy" ] && ok "emit matches the legacy wording byte-for-byte" \
  || fail "emit must stay byte-identical to the legacy wording"
printf '%s\n' "$legacy" > "$TMP/cap"
[ "$(fm_wake_ack_parse_through "$TMP/cap")" = "42" ] && [ "$(fm_wake_ack_parse_generation "$TMP/cap")" = "g1787.tok" ] \
  && ok "a legacy capture parses" || fail "a legacy capture must parse"

# --- 3. malformed lines parse to nothing -----------------------------------
printf 'WAKE_ACK_REQUIRED: run bin/fm-wake-drain.sh --ack-through 5\n' > "$TMP/cap"
[ -z "$(fm_wake_ack_parse_through "$TMP/cap")" ] && ok "a line without a generation parses to nothing" \
  || fail "a line without a generation must parse to nothing"
printf 'WAKE_ACK_REQUIRED: ... --ack-through x9 --recovery-generation tok\n' > "$TMP/cap"
[ -z "$(fm_wake_ack_parse_through "$TMP/cap")" ] && ok "a non-numeric through parses to nothing" \
  || fail "a non-numeric through must parse to nothing"
printf 'WAKE_ACK_REQUIRED: ... --ack-through 5 --recovery-generation tok extra\n' > "$TMP/cap"
[ -z "$(fm_wake_ack_parse_generation "$TMP/cap")" ] && ok "trailing garbage parses to nothing" \
  || fail "trailing garbage must parse to nothing"

# --- 4. the last line wins -------------------------------------------------
{ fm_wake_ack_line 1 alt; fm_wake_ack_line 9 neu; } > "$TMP/cap"
[ "$(fm_wake_ack_parse_through "$TMP/cap")" = "9" ] && [ "$(fm_wake_ack_parse_generation "$TMP/cap")" = "neu" ] \
  && ok "the last line wins" || fail "the last line must win"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-wake-ack-lib.test.sh: all checks passed"
  exit 0
fi
echo "fm-wake-ack-lib.test.sh: $FAILS check(s) FAILED"
exit 1
