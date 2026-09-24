#!/usr/bin/env bash
# Detection-precedence tests for the GitHub Copilot CLI harness adapter.
# docs/verification/copilot.md records the live evidence this pins: COPILOT_CLI=1
# on the CLI's own process and its tool subprocesses, and the exact process name
# `copilot` for the ancestry-based fallback. This adapter is DETECTION-ONLY -
# no spawn, busy-state, or control wiring exists yet - so this file mirrors the
# marker/ancestry precedence style of tests/fm-harness-precedence.test.sh rather
# than a full spawn fixture like tests/fm-grok-harness.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Every case states the markers it means to test. Drop the ambient ones (plus
# COPILOT_CLI itself) so a verdict never depends on which harness launched
# this suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS ATLASSIAN_AGENT_TYPE ROVODEV_CLI COPILOT_CLI

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A real process named after a harness, asked for its own verdict from a child.
# A SYMLINK to the system shell, never a copy: a copied platform binary fails
# macOS code signing (tests/fm-omp-harness.test.sh's make_named_shells records
# the same fact). The `-c` body ends in a no-op so bash does not exec-optimize
# the single command away and replace the named process.
under_process() {  # <named-executable> [VAR=VAL ...]
  local bin=$1
  shift
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u COPILOT_CLI "$@" \
    "$bin" -c 'r=$("$1"); printf "%s" "$r"; :' _ "$HARNESS"
}

# A fake ps that reports a bash ancestor terminating at pid 1, so the ancestry
# layer proves nothing and only the marker layer can answer.
blind_ancestry_bin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

with_blind_ancestry() {  # <fakebin> [VAR=VAL ...]
  local fakebin=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u COPILOT_CLI "$@" \
    PATH="$fakebin:$BASE_PATH" "$HARNESS"
}

named_bin() {  # <dir> <name>
  mkdir -p "$1"
  ln -sf /bin/bash "$1/$2"
  printf '%s\n' "$1/$2"
}

test_copilot_marker_alone_with_ancestry_blind() {
  local fakebin got
  fakebin=$(blind_ancestry_bin "$TMP_ROOT/marker-alone")
  got=$(with_blind_ancestry "$fakebin" COPILOT_CLI=1)
  [ "$got" = copilot ] \
    || fail "COPILOT_CLI=1 with ancestry blind resolved '$got', expected copilot (the marker signal is not live)"
  got=$(with_blind_ancestry "$fakebin")
  [ "$got" = unknown ] \
    || fail "no marker with ancestry blind resolved '$got', expected unknown"
  pass "an inherited COPILOT_CLI marker alone is a live detection signal"
}

test_copilot_ancestry_alone() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/ancestry-alone" copilot)
  got=$(under_process "$bin")
  [ "$got" = copilot ] \
    || fail "an unmarked copilot process resolved '$got', expected copilot (the ancestry signal is not live)"
  pass "the anchored copilot process name alone is a live detection signal"
}

test_copilot_marker_and_ancestry_agree() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/genuine" copilot)
  got=$(under_process "$bin" COPILOT_CLI=1)
  [ "$got" = copilot ] || fail "a genuine copilot session resolved '$got', expected copilot"
  pass "a genuine copilot session is detected with marker and ancestry agreeing"
}

# COPILOT_CLI is checked LAST among markers (docs/verification/copilot.md
# records the survival hazard is unverified), so an already-verified marker
# present alongside it must still win when ancestry is silent.
test_established_marker_outranks_copilot_when_ancestry_is_silent() {
  local fakebin got
  fakebin=$(blind_ancestry_bin "$TMP_ROOT/marker-ordering")
  got=$(with_blind_ancestry "$fakebin" CLAUDECODE=1 COPILOT_CLI=1)
  [ "$got" = claude ] \
    || fail "CLAUDECODE and COPILOT_CLI together with ancestry blind resolved '$got', expected claude"
  pass "an established marker outranks a retained COPILOT_CLI when ancestry cannot arbitrate"
}

# A retained foreign marker must not rename a genuine copilot process tree:
# comm-strength ancestry always outranks a marker disagreement.
test_retained_foreign_marker_does_not_rename_a_nested_copilot() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/nested-copilot" copilot)
  got=$(under_process "$bin" CLAUDECODE=1)
  [ "$got" = copilot ] \
    || fail "a copilot tree carrying a retained CLAUDECODE resolved '$got', expected copilot"
  pass "a retained foreign marker does not rename a nested copilot worker"
}

# The symmetric half: a retained COPILOT_CLI marker must not rename a genuine
# claude process tree either.
test_retained_copilot_marker_does_not_rename_a_nested_claude() {
  local bin got
  bin=$(named_bin "$TMP_ROOT/nested-claude" claude)
  got=$(under_process "$bin" COPILOT_CLI=1 CLAUDECODE=1)
  [ "$got" = claude ] \
    || fail "a claude tree carrying a retained COPILOT_CLI resolved '$got', expected claude"
  pass "a retained COPILOT_CLI marker does not rename a nested claude worker"
}

test_copilot_marker_alone_with_ancestry_blind
test_copilot_ancestry_alone
test_copilot_marker_and_ancestry_agree
test_established_marker_outranks_copilot_when_ancestry_is_silent
test_retained_foreign_marker_does_not_rename_a_nested_copilot
test_retained_copilot_marker_does_not_rename_a_nested_claude
