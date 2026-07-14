#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's own usage surface.
#
# fm-spawn.sh's header IS its usage text, and --help used to print it through a
# hardcoded `sed -n '2,<N>p'` range. Every header line added past N fell off the
# end silently: --help still exited 0 and still looked like help, so the loss was
# invisible until someone diffed it against the source. The range is now derived
# from the header block itself, and this pins that: --help must reach the last
# header line, whatever it happens to be.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"

test_script_parses() {
  bash -n "$SPAWN" 2>&1 || fail "bin/fm-spawn.sh fails bash -n"
  pass "fm-spawn.sh: bash -n succeeds"
}

# The header's last line, read from the source rather than restated here, so this
# keeps testing the real terminator after the header grows again.
last_header_line() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); last = $0; next }
    { exit }
    END { print last }
  ' "$SPAWN"
}

test_help_reaches_the_last_header_line() {
  local help last
  last=$(last_header_line)
  [ -n "$last" ] || fail "fm-spawn-usage: could not read the header's last line from $SPAWN"
  help=$("$SPAWN" --help)
  assert_contains "$help" "$last" \
    "fm-spawn.sh --help stops before the end of its header, so it silently drops usage text"
  pass "fm-spawn.sh: --help renders the complete header, ending at its last line"
}

# The regression that motivated this: the grok turn-end hook lines sit at the very
# bottom of the header and were the ones dropped when the range went stale.
test_help_keeps_the_trailing_hook_notes() {
  local help
  help=$("$SPAWN" --help)
  assert_contains "$help" "grok uses a firstmate-owned global hook" \
    "fm-spawn.sh --help dropped the grok turn-end hook note from the header tail"
  assert_contains "$help" "secondmate spawns record mode=secondmate" \
    "fm-spawn.sh --help dropped the meta-recording note from the header tail"
  pass "fm-spawn.sh: --help keeps the header-tail notes a stale range would drop"
}

test_script_parses
test_help_reaches_the_last_header_line
test_help_keeps_the_trailing_hook_notes
